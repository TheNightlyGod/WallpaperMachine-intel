//! A main-display change moves a reconciled scene's window; it never loads,
//! rebuilds or closes the scene.
use std::{
    cell::{Cell, RefCell},
    sync::{Arc, Mutex},
};

use kameo::actor::Spawn;

use super::EngineActor;
use crate::{
    DisplayDesc, DisplayIdentity, EngineError,
    display::state::{DisplayKey, DisplayStateModel},
    engine::{
        EngineSnapshotPublisher,
        runtime::{RuntimeRefreshJob, RuntimeRefreshMode, SceneRuntime},
        state::EngineState,
    },
    owe::backend::OweBackend,
    project::{SceneDesc, SceneHandle},
    window::MouseButtonTracker,
};

pub(super) fn screen(display_id: u32, uuid: &str, x: i32) -> DisplayDesc {
    let identity = DisplayIdentity {
        uuid: Some(uuid.to_owned()),
        vendor_id: Some(1552),
        model_id: Some(41_000 + display_id),
        serial_number: Some(9_000 + display_id),
        unit_number: Some(display_id),
        name: Some(format!("Panel {display_id}")),
    };
    DisplayDesc::with_identity(display_id, identity, x, 0, 3024, 1964, 2.0)
}

pub(super) fn builtin() -> DisplayDesc {
    screen(1, "builtin-panel", 0)
}

pub(super) fn external() -> DisplayDesc {
    screen(5, "external-panel", 1512)
}

pub(super) fn scene(display: &DisplayDesc, wallpaper: &str) -> SceneDesc {
    SceneDesc::builder(display.clone(), format!("/library/{wallpaper}/scene.json"))
        .fps(48)
        .build()
        .expect("a valid scene descriptor")
}

pub(super) fn engine_for(model: DisplayStateModel) -> EngineActor {
    let state = EngineState::with_display_model(model);
    let buttons = Arc::new(Mutex::new(MouseButtonTracker::with_press_test(Box::new(
        || true,
    ))));
    let snapshots = Arc::new(EngineSnapshotPublisher::new(state.snapshot(), buttons));
    let prepared = EngineActor::prepare();
    EngineActor::new(
        OweBackend,
        Arc::new(|_| {}),
        state,
        snapshots,
        prepared.actor_ref().downgrade(),
    )
}

/// What the device-free runtime facade was asked to do.
#[derive(Default)]
pub(super) struct RuntimeFacade {
    pub(super) jobs: RefCell<Vec<(DisplayKey, RuntimeRefreshMode)>>,
    pub(super) closes: Cell<usize>,
}

impl RuntimeFacade {
    /// Runs one display-state update with this facade standing in for the
    /// renderer: a job opens a windowless scene (or keeps the one it was
    /// handed), a close is only counted.
    pub(super) fn update(
        &self,
        actor: &mut EngineActor,
        update: impl FnOnce(&mut DisplayStateModel) -> Result<(), EngineError>,
    ) -> Result<(), EngineError> {
        actor.update_display_state_with(
            update,
            |_runtime| {
                self.closes.set(self.closes.get() + 1);
                Ok(())
            },
            |actor| actor.open_required_with(|actor, job| self.run(actor, job)),
        )
    }

    fn run(&self, actor: &mut EngineActor, job: RuntimeRefreshJob) -> Result<(), EngineError> {
        let mode = RuntimeRefreshMode::from_transition(
            job.existing_runtime.as_ref().map(|runtime| &runtime.desc),
            &job.desc,
        );
        self.jobs.borrow_mut().push((job.key.clone(), mode));
        let runtime = match job.existing_runtime {
            Some(runtime) => runtime,
            None => SceneRuntime::windowless_for_test(
                job.handle,
                &job.desc,
                &job.runtime_state,
                actor.weak_self.clone(),
            )?,
        };
        actor.store_runtime(&job.key, job.handle, runtime)
    }

    pub(super) fn forget(&self) {
        self.jobs.borrow_mut().clear();
        self.closes.set(0);
    }
}

/// The slot whose live scene runs on `display`, its handle and its wallpaper.
pub(super) fn running_on(actor: &EngineActor, display: &DisplayDesc) -> (DisplayKey, SceneHandle, String) {
    let record = actor
        .state
        .display_records
        .iter()
        .find(|record| {
            record.runtime.is_some()
                && record
                    .model
                    .live_display
                    .as_ref()
                    .is_some_and(|live| live.display_id == display.display_id)
        })
        .unwrap_or_else(|| panic!("no live scene on display {}", display.display_id));
    let runtime = record.runtime.as_ref().expect("checked above");
    (
        record.model.key.clone(),
        record.handle.expect("a live scene has a handle"),
        runtime.desc.scene_path.clone(),
    )
}

#[test]
fn a_main_display_change_keeps_each_reconciled_scene_on_its_display_without_reloading() {
    let tokio = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("test runtime");
    let _context = tokio.enter();

    let mut model = DisplayStateModel::from_config(crate::WallpaperEngineConfig::default())
        .expect("default model");
    model
        .refresh_connected(builtin(), vec![builtin(), external()])
        .expect("first report");
    let mut actor = engine_for(model);
    let facade = RuntimeFacade::default();
    facade
        .update(&mut actor, |model| {
            model.apply_reconcile(&[scene(&builtin(), "aurora"), scene(&external(), "basalt")])
        })
        .expect("reconcile");
    assert_eq!(facade.jobs.borrow().len(), 2, "both scenes opened once");
    let (_, builtin_handle, builtin_wallpaper) = running_on(&actor, &builtin());
    let (_, external_handle, external_wallpaper) = running_on(&actor, &external());
    assert!(builtin_wallpaper.contains("aurora") && external_wallpaper.contains("basalt"));
    facade.forget();

    // macOS makes the external display the main one; nothing else changes.
    facade
        .update(&mut actor, |model| {
            model
                .refresh_connected_keeping(external(), vec![builtin(), external()], &[])
                .map(|_| ())
        })
        .expect("main display change");

    assert!(
        facade.jobs.borrow().is_empty(),
        "no scene is opened, rebuilt or reconfigured: {:?}",
        facade.jobs.borrow()
    );
    assert_eq!(facade.closes.get(), 0, "no scene is closed");

    let (builtin_key, handle, wallpaper) = running_on(&actor, &builtin());
    assert_eq!(
        (handle, wallpaper.as_str()),
        (builtin_handle, builtin_wallpaper.as_str())
    );
    assert_ne!(
        builtin_key,
        DisplayKey::Primary,
        "the built-in display is no longer main"
    );
    let (external_key, handle, wallpaper) = running_on(&actor, &external());
    assert_eq!(
        (handle, wallpaper.as_str()),
        (external_handle, external_wallpaper.as_str())
    );
    assert_eq!(
        external_key,
        DisplayKey::Primary,
        "the primary slot follows the main display"
    );

    // The handles the host addresses keep naming the same scenes.
    for (key, handle) in [
        (builtin_key, builtin_handle),
        (external_key, external_handle),
    ] {
        assert_eq!(actor.handle_for_key(&key).expect("lookup"), Some(handle));
    }
    let snapshot = actor.state.snapshot();
    for (display, handle) in [(builtin(), builtin_handle), (external(), external_handle)] {
        let entry = snapshot
            .displays
            .iter()
            .find(|entry| entry.desc.display_id == display.display_id)
            .expect("display listed");
        assert_eq!(entry.handle, Some(handle));
    }
}

#[test]
fn the_old_main_display_keeps_its_scene_when_the_new_main_display_has_none() {
    let tokio = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("test runtime");
    let _context = tokio.enter();

    let mut model = DisplayStateModel::from_config(crate::WallpaperEngineConfig::default())
        .expect("default model");
    model
        .refresh_connected(builtin(), vec![builtin(), external()])
        .expect("first report");
    let mut actor = engine_for(model);
    let facade = RuntimeFacade::default();
    // Only the built-in display shows a wallpaper; the external one is idle.
    facade
        .update(&mut actor, |model| {
            model.apply_reconcile(&[scene(&builtin(), "aurora")])
        })
        .expect("reconcile");
    let (key, builtin_handle, _) = running_on(&actor, &builtin());
    assert_eq!(key, DisplayKey::Primary);
    facade.forget();

    facade
        .update(&mut actor, |model| {
            model
                .refresh_connected_keeping(external(), vec![builtin(), external()], &[])
                .map(|_| ())
        })
        .expect("main display change");

    assert!(
        facade.jobs.borrow().is_empty(),
        "the scene is neither reopened nor rebuilt: {:?}",
        facade.jobs.borrow()
    );
    assert_eq!(facade.closes.get(), 0, "no scene is closed");
    let (key, handle, wallpaper) = running_on(&actor, &builtin());
    assert_ne!(key, DisplayKey::Primary);
    assert_eq!(handle, builtin_handle);
    assert!(wallpaper.contains("aurora"));
    assert!(
        actor
            .state
            .display_records
            .iter()
            .all(|record| record.model.key != DisplayKey::Primary || record.runtime.is_none()),
        "the primary slot, now on a display without a wallpaper, runs nothing"
    );
}
