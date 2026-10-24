//! A wallpaper whose scene load killed the previous process twice in a row is
//! not reopened by startup or by anything after it, until the user applies it
//! again. The fake engine cannot crash the process, so a crash is played by a
//! journal ticket that never ends and a journal opened afterwards.

use std::{
    fs, mem,
    path::Path,
    sync::Arc,
    thread,
    time::{Duration, Instant},
};

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, WallpaperAssignment,
    project::{SceneHandle, SceneTemplate},
};

use crate::{
    WallpaperBridge,
    api::BridgeBuilder,
    config::{AppConfig, ConfigStore, MonitorCfg, SerializedSelector, WallpaperConfig},
    engine::{FakeEngineFacade, LoadJournal, build_stamp},
    paths::BridgePaths,
};

const FOREST: &str = "100";
const LAKE: &str = "200";

struct Setup {
    _home: tempfile::TempDir,
    root: tempfile::TempDir,
    paths: BridgePaths,
}

impl Setup {
    /// Two installed scene wallpapers, FOREST on display 7 and LAKE on display 8.
    fn new() -> Self {
        let home = tempfile::tempdir().unwrap();
        let paths = BridgePaths::for_home(home.path());
        for (id, title) in [
            (FOREST, "Moody Forest"),
            (LAKE, "Quiet Lake"),
            ("300", "Night City"),
        ] {
            let dir = paths.steam_workshop_root().join(id);
            fs::create_dir_all(&dir).unwrap();
            fs::write(
                dir.join("project.json"),
                format!(r#"{{"type":"scene","title":"{title}","file":"scene.json"}}"#),
            )
            .unwrap();
        }
        let root = tempfile::tempdir().unwrap();
        let store = ConfigStore::open(root.path().to_path_buf());
        let mut config = AppConfig::default();
        for (display_id, wallpaper) in [(7, FOREST), (8, LAKE)] {
            config.monitors.push(MonitorCfg {
                selector: SerializedSelector::LiveDisplayId { display_id },
                enabled: true,
                mode: "independent".to_string(),
                wallpaper: Some(wallpaper.to_string()),
                mirror_target: None,
            });
            store
                .save_wallpaper(&WallpaperConfig::new_for(wallpaper, "scene"))
                .unwrap();
        }
        store.save_app_config(&config).unwrap();
        Self {
            _home: home,
            root,
            paths,
        }
    }

    fn engine(&self) -> FakeEngineFacade {
        let engine = FakeEngineFacade::default();
        engine.set_snapshot_after_refresh(vec![display(7), display(8)]);
        engine
    }

    fn bridge(&self, engine: &FakeEngineFacade) -> WallpaperBridge {
        BridgeBuilder::new(engine.clone())
            .with_config_store(ConfigStore::open(self.root.path().to_path_buf()))
            .with_paths(self.paths.clone())
            .build()
            .expect("bridge on a temporary support root")
    }

    fn journal(&self) -> LoadJournal {
        LoadJournal::open(Some(self.root.path()), &build_stamp())
    }

    /// A launch that died while opening `wallpaper`: its record never ended.
    fn die_while_opening(&self, wallpaper: &str, display_id: u32) {
        mem::forget(
            self.journal()
                .begin(vec![(wallpaper.to_string(), display_id)]),
        );
    }

    fn journal_file(&self) -> serde_json::Value {
        journal_file(self.root.path())
    }
}

fn journal_file(root: &Path) -> serde_json::Value {
    serde_json::from_slice(&fs::read(root.join("load-journal.json")).unwrap()).unwrap()
}

/// The entries of the journal file whose scene has not reported a first frame.
fn opening(file: &serde_json::Value) -> Vec<(String, u64)> {
    let mut entries: Vec<(String, u64)> = file["in_flight"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|entry| entry["settled_until"].is_null())
        .map(|entry| {
            (
                entry["wallpaper"].as_str().unwrap().to_string(),
                entry["display"].as_u64().unwrap(),
            )
        })
        .collect();
    entries.sort();
    entries
}

fn display(display_id: u32) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc: DisplayDesc::with_identity(
            display_id,
            DisplayIdentity::default(),
            0,
            0,
            1920,
            1080,
            1.0,
        )
        .with_refresh_rate(60),
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

fn scene_displays(scenes: &[wallpaper_core::project::SceneDesc]) -> Vec<u32> {
    let mut displays: Vec<u32> = scenes
        .iter()
        .map(|scene| scene.display.display_id)
        .collect();
    displays.sort_unstable();
    displays
}

#[tokio::test]
async fn bootstrap_does_not_reopen_a_wallpaper_that_crashed_the_app_twice() {
    let setup = Setup::new();
    setup.die_while_opening(FOREST, 7);
    setup.die_while_opening(FOREST, 7);
    let engine = setup.engine();
    let bridge = setup.bridge(&engine);

    bridge.bootstrap().await.unwrap();

    let calls = engine.calls();
    assert_eq!(calls.len(), 1);
    assert_eq!(
        scene_displays(&calls[0]),
        vec![8],
        "only the wallpaper that did not crash the app is handed to the engine"
    );
    let app = bridge.app_snapshot().await.unwrap();
    assert_eq!(app.active_wallpaper_ids, vec![LAKE.to_string()]);
    assert_eq!(
        app.held_wallpaper_ids,
        vec![FOREST.to_string()],
        "the held wallpaper has to be named, or its display just looks broken"
    );
    assert!(
        app.errors.is_empty(),
        "the hold is reported as state for the panel to word, not as an error line: {:?}",
        app.errors
    );
    // Nothing was deleted: the wallpaper is still installed and still assigned.
    let library = bridge.library_snapshot().await.unwrap();
    assert!(library.wallpapers.iter().any(|entry| entry.id == FOREST));
    let saved = ConfigStore::open(setup.root.path().to_path_buf())
        .load()
        .unwrap()
        .config;
    assert!(
        saved
            .monitors
            .iter()
            .any(|monitor| monitor.wallpaper.as_deref() == Some(FOREST)),
        "the assignment survives, so applying it again is all it takes"
    );
}

#[tokio::test]
async fn one_earlier_crash_is_not_enough_to_hold_a_wallpaper_back() {
    let setup = Setup::new();
    setup.die_while_opening(FOREST, 7);
    let engine = setup.engine();
    let bridge = setup.bridge(&engine);

    bridge.bootstrap().await.unwrap();

    assert_eq!(scene_displays(&engine.calls()[0]), vec![7, 8]);
    let app = bridge.app_snapshot().await.unwrap();
    assert!(app.held_wallpaper_ids.is_empty());
    assert!(app.errors.is_empty());
}

#[tokio::test]
async fn applying_a_held_wallpaper_again_opens_it_and_releases_the_hold() {
    let setup = Setup::new();
    setup.die_while_opening(FOREST, 7);
    setup.die_while_opening(FOREST, 7);
    let engine = setup.engine();
    let bridge = setup.bridge(&engine);
    bridge.bootstrap().await.unwrap();
    assert_eq!(scene_displays(&engine.calls()[0]), vec![8]);

    // Nothing in the draft changed, which is the case that normally
    // reconciles nothing at all.
    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options(FOREST.to_string(), true)
        .await
        .unwrap();
    assert!(done.wait(Duration::from_secs(5)));

    let calls = engine.calls();
    assert_eq!(
        scene_displays(calls.last().unwrap()),
        vec![7, 8],
        "Apply is the way back, and it must reach the engine"
    );
    let app = bridge.app_snapshot().await.unwrap();
    assert_eq!(
        app.active_wallpaper_ids,
        vec![FOREST.to_string(), LAKE.to_string()]
    );
    assert!(
        app.held_wallpaper_ids.is_empty(),
        "the notice goes away with the hold: {:?}",
        app.held_wallpaper_ids
    );
    assert!(
        setup.journal_file()["strikes"].get(FOREST).is_none(),
        "the release is saved, or the next launch would hold it again"
    );

    // And later reconciles keep it.
    let calls_before = engine.calls().len();
    bridge.refresh_displays().await.unwrap();
    let calls = engine.calls();
    assert!(calls.len() > calls_before, "a display refresh reconciles");
    assert_eq!(
        scene_displays(calls.last().unwrap()),
        vec![7, 8],
        "a released wallpaper stays in every later plan"
    );
}

#[test]
fn a_crash_while_a_held_wallpaper_is_applied_again_holds_it_at_the_next_launch() {
    let setup = Setup::new();
    setup.die_while_opening(FOREST, 7);
    setup.die_while_opening(FOREST, 7);
    let engine = setup.engine();
    let bridge = Arc::new(setup.bridge(&engine));
    tokio::runtime::Runtime::new()
        .unwrap()
        .block_on(bridge.bootstrap())
        .unwrap();
    assert_eq!(scene_displays(&engine.calls()[0]), vec![8]);

    let block = engine.block_next_reconcile();
    let applying = Arc::clone(&bridge);
    let apply = thread::spawn(move || {
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(applying.apply_wallpaper_options(FOREST.to_string(), true))
    });
    assert!(
        block.wait_until_blocked(Duration::from_secs(10)),
        "the apply never reached the engine"
    );

    // The process dies here, with the scene still loading. Try again keeps the
    // strikes until the load has succeeded, and so must Apply: otherwise the
    // wallpaper that crashed the app twice comes back as a first offence, is
    // opened by startup, and crashes the app a third time before the user can
    // do anything.
    let file = setup.journal_file();
    assert_eq!(
        file["strikes"][FOREST]["count"], 2,
        "the hold is not lifted before the load has been survived: {file}"
    );
    assert!(opening(&file).contains(&(FOREST.to_string(), 7)));
    let next_launch = setup.journal();
    assert_eq!(next_launch.strikes()[FOREST].count, 3);
    assert!(
        next_launch.held().contains(FOREST),
        "the next launch holds it again"
    );

    block.release();
    apply.join().unwrap().unwrap();
    assert!(
        setup.journal_file()["strikes"].get(FOREST).is_none(),
        "a load that got through is forgiven"
    );
}

#[tokio::test]
async fn an_apply_that_fails_leaves_a_held_wallpaper_held() {
    let setup = Setup::new();
    setup.die_while_opening(FOREST, 7);
    setup.die_while_opening(FOREST, 7);
    let engine = setup.engine();
    let bridge = setup.bridge(&engine);
    bridge.bootstrap().await.unwrap();

    engine.fail_reconcile_with("engine unavailable");
    let error = bridge
        .apply_wallpaper_options(FOREST.to_string(), true)
        .await
        .expect_err("the engine refused the reconcile");
    assert!(error.message().contains("engine unavailable"));
    // A failed apply is followed by a repair, which the engine refuses as well.
    tokio::time::timeout(Duration::from_secs(5), async {
        while bridge.app_snapshot().await.unwrap().errors.len() < 2 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the repair after a failed apply never finished");

    assert_eq!(
        bridge.app_snapshot().await.unwrap().held_wallpaper_ids,
        vec![FOREST.to_string()],
        "an apply that opened nothing must not look like a release"
    );
    assert_eq!(
        setup.journal_file()["strikes"][FOREST]["count"],
        2,
        "and the next launch still holds it back"
    );
    assert_eq!(
        scene_displays(engine.calls().last().unwrap()),
        vec![8],
        "the repair that follows the failure does not reopen what the apply could not"
    );

    // Applying it again works once the engine does.
    engine.clear_reconcile_failure();
    bridge
        .apply_wallpaper_options(FOREST.to_string(), true)
        .await
        .unwrap();
    assert!(
        bridge
            .app_snapshot()
            .await
            .unwrap()
            .held_wallpaper_ids
            .is_empty()
    );
    assert!(setup.journal_file()["strikes"].get(FOREST).is_none());
}

#[tokio::test]
async fn app_snapshot_lists_held_ids_sorted() {
    let setup = Setup::new();
    // Held in the opposite order to the one they sort in.
    for _ in 0..2 {
        setup.die_while_opening(LAKE, 8);
    }
    for _ in 0..2 {
        setup.die_while_opening(FOREST, 7);
    }
    let engine = setup.engine();
    let bridge = setup.bridge(&engine);

    let bundle = bridge.bootstrap().await.unwrap();

    let expected = vec![FOREST.to_string(), LAKE.to_string()];
    assert_eq!(bundle.app.held_wallpaper_ids, expected);
    assert_eq!(
        bridge.app_snapshot().await.unwrap().held_wallpaper_ids,
        expected,
        "every snapshot carries the same list as the bootstrap bundle"
    );
    assert!(
        engine.calls().iter().all(|scenes| scenes.is_empty()),
        "with every assignment held, nothing is handed to the engine"
    );
}

#[tokio::test]
async fn release_held_wallpaper_reconciles_it_and_empties_the_snapshot_field() {
    let setup = Setup::new();
    setup.die_while_opening(FOREST, 7);
    setup.die_while_opening(FOREST, 7);
    let engine = setup.engine();
    let bridge = setup.bridge(&engine);
    bridge.bootstrap().await.unwrap();
    assert_eq!(scene_displays(&engine.calls()[0]), vec![8]);
    let calls_before = engine.calls().len();

    let bundle = bridge
        .release_held_wallpaper(FOREST.to_string())
        .await
        .unwrap();

    assert!(bundle.app.held_wallpaper_ids.is_empty());
    assert_eq!(
        bundle.app.active_wallpaper_ids,
        vec![FOREST.to_string(), LAKE.to_string()],
        "the reply already shows the wallpaper as opened"
    );
    let calls = engine.calls();
    assert!(
        calls.len() > calls_before,
        "the engine was asked to open it"
    );
    assert_eq!(scene_displays(calls.last().unwrap()), vec![7, 8]);
    assert!(
        setup.journal_file()["strikes"].get(FOREST).is_none(),
        "the release is saved, or the next launch would hold it again"
    );
    assert!(
        bridge
            .app_snapshot()
            .await
            .unwrap()
            .held_wallpaper_ids
            .is_empty()
    );
}

#[tokio::test]
async fn releasing_a_wallpaper_that_is_not_held_changes_nothing() {
    let setup = Setup::new();
    setup.die_while_opening(FOREST, 7);
    setup.die_while_opening(FOREST, 7);
    let engine = setup.engine();
    let bridge = setup.bridge(&engine);
    bridge.bootstrap().await.unwrap();
    let calls_before = engine.calls().len();

    // A stale click on a tile the panel has already moved past.
    let bundle = bridge
        .release_held_wallpaper(LAKE.to_string())
        .await
        .unwrap();

    assert_eq!(bundle.app.held_wallpaper_ids, vec![FOREST.to_string()]);
    assert_eq!(engine.calls().len(), calls_before, "nothing was reopened");
    assert_eq!(setup.journal_file()["strikes"][FOREST]["count"], 2);
}

#[tokio::test]
async fn a_release_that_fails_leaves_the_wallpaper_held() {
    let setup = Setup::new();
    setup.die_while_opening(FOREST, 7);
    setup.die_while_opening(FOREST, 7);
    let engine = setup.engine();
    let bridge = setup.bridge(&engine);
    bridge.bootstrap().await.unwrap();

    engine.fail_reconcile_with("engine unavailable");
    let error = bridge
        .release_held_wallpaper(FOREST.to_string())
        .await
        .expect_err("the engine refused the reconcile");
    assert!(error.message().contains("engine unavailable"));

    assert_eq!(
        bridge.app_snapshot().await.unwrap().held_wallpaper_ids,
        vec![FOREST.to_string()],
        "a retry that opened nothing must not look like a release"
    );
    assert_eq!(
        setup.journal_file()["strikes"][FOREST]["count"],
        2,
        "and the next launch still holds it back"
    );

    // The retry works once the engine does.
    engine.clear_reconcile_failure();
    let bundle = bridge
        .release_held_wallpaper(FOREST.to_string())
        .await
        .unwrap();
    assert!(bundle.app.held_wallpaper_ids.is_empty());
    assert!(setup.journal_file()["strikes"].get(FOREST).is_none());
}

#[tokio::test]
async fn a_hold_on_a_wallpaper_no_display_shows_is_not_reported() {
    let setup = Setup::new();
    setup.die_while_opening(FOREST, 7);
    setup.die_while_opening(FOREST, 7);
    let engine = setup.engine();
    let bridge = setup.bridge(&engine);
    bridge.bootstrap().await.unwrap();
    assert_eq!(
        bridge.app_snapshot().await.unwrap().held_wallpaper_ids,
        vec![FOREST.to_string()]
    );

    // Display 7 is given another wallpaper, so nothing waits for FOREST.
    bridge
        .set_display_config_enabled("300".to_string(), "7".to_string(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("300".to_string(), true)
        .await
        .unwrap();

    assert!(
        bridge
            .app_snapshot()
            .await
            .unwrap()
            .held_wallpaper_ids
            .is_empty(),
        "a banner about a wallpaper no display wants would be noise"
    );
    assert_eq!(
        setup.journal_file()["strikes"][FOREST]["count"],
        2,
        "the hold itself is not forgotten"
    );
}

#[tokio::test]
async fn a_hold_blocks_later_reconciles_as_well_as_startup() {
    let setup = Setup::new();
    setup.die_while_opening(FOREST, 7);
    setup.die_while_opening(FOREST, 7);
    let engine = setup.engine();
    let bridge = setup.bridge(&engine);
    bridge.bootstrap().await.unwrap();

    // Applying a different wallpaper reconciles every display.
    let done = engine.wait_for_next_reconcile();
    bridge
        .set_display_config_enabled("300".to_string(), "8".to_string(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("300".to_string(), true)
        .await
        .unwrap();
    assert!(done.wait(Duration::from_secs(5)));

    let calls = engine.calls();
    let last = calls.last().unwrap();
    assert_eq!(
        scene_displays(last),
        vec![8],
        "the held wallpaper's display is still left alone"
    );
    assert!(last[0].scene_path.contains("/300/"));
}

#[tokio::test]
async fn a_playlist_coming_back_to_a_held_wallpaper_does_not_reopen_it() {
    let setup = Setup::new();
    setup.die_while_opening(FOREST, 7);
    setup.die_while_opening(FOREST, 7);
    let engine = setup.engine();
    let bridge = setup.bridge(&engine);
    bridge.bootstrap().await.unwrap();

    // A rotation moves display 7 on and then comes round to FOREST again. It
    // applies the wallpaper the way the user's Apply does, without the user.
    for wallpaper in ["300", FOREST] {
        let done = engine.wait_for_next_reconcile();
        bridge
            .set_display_config_enabled(wallpaper.to_string(), "7".to_string(), true)
            .await
            .unwrap();
        bridge
            .apply_wallpaper_options(wallpaper.to_string(), false)
            .await
            .unwrap();
        assert!(done.wait(Duration::from_secs(5)));
    }

    let calls = engine.calls();
    assert_eq!(
        scene_displays(calls.last().unwrap()),
        vec![8],
        "FOREST crashed the app twice: a schedule does not get to reopen it"
    );
    let app = bridge.app_snapshot().await.unwrap();
    assert_eq!(
        app.held_wallpaper_ids,
        vec![FOREST.to_string()],
        "display 7 is waiting for it again, so the panel says why it is empty"
    );
    assert_eq!(
        setup.journal_file()["strikes"][FOREST]["count"],
        2,
        "and the next launch holds it as well"
    );

    // The user choosing it is still the way back.
    let done = engine.wait_for_next_reconcile();
    bridge
        .apply_wallpaper_options(FOREST.to_string(), true)
        .await
        .unwrap();
    assert!(done.wait(Duration::from_secs(5)));
    assert_eq!(scene_displays(engine.calls().last().unwrap()), vec![7, 8]);
    assert!(
        bridge
            .app_snapshot()
            .await
            .unwrap()
            .held_wallpaper_ids
            .is_empty()
    );
    assert!(setup.journal_file()["strikes"].get(FOREST).is_none());
}

#[tokio::test]
async fn an_automated_apply_does_not_start_a_strike_count_over() {
    let setup = Setup::new();
    setup.die_while_opening(FOREST, 7);
    let engine = setup.engine();
    let bridge = setup.bridge(&engine);
    bridge.bootstrap().await.unwrap();
    assert_eq!(setup.journal_file()["strikes"][FOREST]["count"], 1);

    bridge
        .apply_wallpaper_options(FOREST.to_string(), false)
        .await
        .unwrap();

    assert_eq!(
        setup.journal_file()["strikes"][FOREST]["count"],
        1,
        "a rule applying it again says nothing about whether it still crashes"
    );

    bridge
        .apply_wallpaper_options(FOREST.to_string(), true)
        .await
        .unwrap();

    assert!(
        setup.journal_file()["strikes"].get(FOREST).is_none(),
        "the user applying it again does start the count over"
    );
}

#[test]
fn a_load_is_on_record_while_it_runs_and_through_its_settle_window() {
    let setup = Setup::new();
    let engine = setup.engine();
    let bridge = Arc::new(setup.bridge(&engine));
    let block = engine.block_next_reconcile();
    let starting = Arc::clone(&bridge);
    let startup = thread::spawn(move || {
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(starting.bootstrap())
    });
    assert!(
        block.wait_until_blocked(Duration::from_secs(10)),
        "startup never reached the engine"
    );

    assert_eq!(
        opening(&setup.journal_file()),
        vec![(FOREST.to_string(), 7), (LAKE.to_string(), 8)],
        "both scenes are on record before the engine is asked to open them"
    );

    block.release();
    startup.join().unwrap().unwrap();
    let settling = setup.journal_file();
    assert!(
        opening(&settling).is_empty(),
        "every scene has reported its first frame"
    );
    assert_eq!(
        settling["in_flight"].as_array().unwrap().len(),
        2,
        "but a crash just after the first frame still has to be attributed: {settling}"
    );

    // The process dies now. The next launch finds the record.
    let next = setup.journal();
    assert_eq!(next.strikes()[FOREST].count, 1);
    assert_eq!(next.strikes()[LAKE].count, 1);
}

#[test]
fn only_the_scenes_that_actually_open_are_suspects() {
    let setup = Setup::new();
    let engine = setup.engine();
    let bridge = Arc::new(setup.bridge(&engine));
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        bridge.bootstrap().await.unwrap();
    });
    // Both scenes are now running exactly as planned.
    let running: Vec<DisplaySnapshotEntry> = engine
        .rendered_scenes()
        .iter()
        .map(|scene| DisplaySnapshotEntry {
            handle: Some(SceneHandle::new(u64::from(scene.display.display_id))),
            assignment: Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(
                scene,
            ))),
            ..display(scene.display.display_id)
        })
        .collect();
    assert_eq!(running.len(), 2);
    engine.set_snapshot(running);

    let block = engine.block_next_reconcile();
    let applying = Arc::clone(&bridge);
    let apply = thread::spawn(move || {
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            applying
                .set_display_config_enabled("300".to_string(), "8".to_string(), true)
                .await
                .unwrap();
            applying
                .apply_wallpaper_options("300".to_string(), true)
                .await
        })
    });
    assert!(block.wait_until_blocked(Duration::from_secs(10)));

    assert_eq!(
        opening(&setup.journal_file()),
        vec![("300".to_string(), 8)],
        "the scene on display 7 is already running and cannot be what dies"
    );
    block.release();
    apply.join().unwrap().unwrap();
}

#[test]
fn quitting_while_a_scene_is_loading_leaves_no_strike() {
    let setup = Setup::new();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(7)]);
    // Nothing is assigned yet, so startup opens nothing and writes nothing.
    fs::remove_file(setup.root.path().join("config.toml")).unwrap();
    let bridge = Arc::new(setup.bridge(&engine));
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async { bridge.bootstrap().await.unwrap() });
    assert!(
        !setup.root.path().join("load-journal.json").exists(),
        "a launch that opens nothing never writes the journal"
    );

    let block = engine.block_next_reconcile();
    let applying = Arc::clone(&bridge);
    let apply = thread::spawn(move || {
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            applying
                .set_display_config_enabled(FOREST.to_string(), "7".to_string(), true)
                .await
                .unwrap();
            applying
                .apply_wallpaper_options(FOREST.to_string(), true)
                .await
        })
    });
    assert!(block.wait_until_blocked(Duration::from_secs(10)));
    assert_eq!(
        opening(&setup.journal_file()),
        vec![(FOREST.to_string(), 7)]
    );

    runtime.block_on(bridge.shutdown()).unwrap();
    assert!(
        setup.journal_file()["in_flight"]
            .as_array()
            .unwrap()
            .is_empty(),
        "quitting is not a crash"
    );

    // The load that was cut short still finishes; it must not write itself
    // back as if the app were still running.
    block.release();
    let _ = apply.join().unwrap();
    assert!(
        setup.journal_file()["in_flight"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(setup.journal().strikes().is_empty());
}

/// Waits until the journal file has nothing in flight, which is how a test sees
/// that the record was closed from outside the actor.
fn wait_until_nothing_is_in_flight(setup: &Setup) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let in_flight = setup.journal_file()["in_flight"].as_array().unwrap().len();
        if in_flight == 0 {
            return;
        }
        assert!(Instant::now() < deadline, "the record was never closed");
        thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn quitting_while_startup_is_still_loading_leaves_no_strike() {
    let setup = Setup::new();
    let engine = setup.engine();
    let bridge = Arc::new(setup.bridge(&engine));
    let block = engine.block_next_reconcile();
    let starting = Arc::clone(&bridge);
    let startup = thread::spawn(move || {
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(starting.bootstrap())
    });
    assert!(
        block.wait_until_blocked(Duration::from_secs(10)),
        "startup never reached the engine"
    );
    assert_eq!(
        opening(&setup.journal_file()),
        vec![(FOREST.to_string(), 7), (LAKE.to_string(), 8)]
    );

    // Startup holds the actor until its scenes have opened, so the quit's own
    // request waits behind it. The record has to close without the actor.
    let quitting = Arc::clone(&bridge);
    let quit = thread::spawn(move || {
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(quitting.shutdown())
    });
    wait_until_nothing_is_in_flight(&setup);
    assert!(
        !quit.is_finished(),
        "the actor is still inside startup, so only the journal can have been closed"
    );
    assert!(
        setup.journal().strikes().is_empty(),
        "a process that is killed now left nothing for the next launch to count"
    );

    block.release();
    startup.join().unwrap().unwrap();
    quit.join().unwrap().unwrap();
    assert!(
        setup.journal_file()["in_flight"]
            .as_array()
            .unwrap()
            .is_empty(),
        "the load that finished late must not write itself back"
    );
    assert!(setup.journal().strikes().is_empty());
}

#[test]
fn a_load_that_starts_after_the_quit_began_is_not_recorded() {
    let setup = Setup::new();
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![display(7)]);
    // Nothing is assigned yet, so startup opens nothing and writes nothing.
    fs::remove_file(setup.root.path().join("config.toml")).unwrap();
    let bridge = Arc::new(setup.bridge(&engine));
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async { bridge.bootstrap().await.unwrap() });
    runtime.block_on(bridge.shutdown()).unwrap();

    // Something queued behind the quit still opens a scene (a rule firing as
    // the services stop, say). The app is on its way out: it is not a suspect.
    let block = engine.block_next_reconcile();
    let applying = Arc::clone(&bridge);
    let apply = thread::spawn(move || {
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            applying
                .set_display_config_enabled(FOREST.to_string(), "7".to_string(), true)
                .await
                .unwrap();
            applying
                .apply_wallpaper_options(FOREST.to_string(), true)
                .await
        })
    });
    assert!(
        block.wait_until_blocked(Duration::from_secs(10)),
        "the late apply never reached the engine"
    );
    let recorded = setup.root.path().join("load-journal.json").exists()
        && !setup.journal_file()["in_flight"]
            .as_array()
            .unwrap()
            .is_empty();
    assert!(!recorded, "nothing opened after the quit began is recorded");

    block.release();
    let _ = apply.join().unwrap();
    assert!(setup.journal().strikes().is_empty());
}

#[test]
fn a_failed_load_leaves_no_strike() {
    let setup = Setup::new();
    let engine = setup.engine();
    engine.fail_reconcile_with("the scene could not be opened");
    let bridge = setup.bridge(&engine);
    let runtime = tokio::runtime::Runtime::new().unwrap();

    runtime.block_on(async { bridge.bootstrap().await.unwrap() });

    assert!(
        setup.journal_file()["in_flight"]
            .as_array()
            .unwrap()
            .is_empty(),
        "an error was reported by a process that is still alive"
    );
    assert!(setup.journal().strikes().is_empty());
}
