use super::{OwnedRoot, PanicPayload, TestBody, WATCHDOG};

use std::{fs, panic::{resume_unwind, AssertUnwindSafe}, path::PathBuf};

use futures_util::FutureExt;

use crate::api::{
    BridgeBuilder, BridgeDisplayMode, BridgeError, BridgeErrorKind, BridgeLibrarySnapshot,
    BridgeMonitorInformationSnapshot, BridgeScalingMode, BridgeSettingsSnapshot,
    BridgeSnapshotBundle, BridgeWallpaperKind, WallpaperBridge,
};
use crate::config::{
    AppConfig, ConfigStore, MonitorCfg, MonitorRender, SerializedSelector, WallpaperConfig,
};
use crate::display::{DisplayLabelExt, DisplaySelectorExt, DisplaySnapshotExt};
use crate::engine::{EngineFacade, FakeEngineFacade};
use crate::paths::BridgePaths;
use wallpaper_core::project::{SceneDesc, SceneHandle, SceneTemplate};
use wallpaper_core::{DisplayDesc, DisplayIdentity, DisplaySelector, DisplaySnapshotEntry, WallpaperAssignment};

// Only the accepted facade supplies synthetic rendering. All bridge requests,
// configuration loads, library scans, publication and teardown below are real.
async fn with_intent_bridge<S, F>(prepare: S, body: F)
where
    S: FnOnce(&OwnedRoot, &BridgePaths, &ConfigStore) -> Vec<DisplaySnapshotEntry>,
    F: for<'a> FnOnce(
        &'a OwnedRoot,
        &'a BridgePaths,
        &'a ConfigStore,
        &'a WallpaperBridge,
        &'a FakeEngineFacade,
    ) -> TestBody<'a>,
{
    let mut root = OwnedRoot::new();
    let paths = root.bridge_paths();
    let store_root = root.checked(root.path.join("consumer-settings"));
    fs::create_dir_all(&store_root).expect("create this consumer's owned configuration store");
    root.checked(store_root.join("config.toml"));
    root.checked(store_root.join("wallpapers"));
    root.checked(store_root.join("load-journal.json"));
    let store = ConfigStore::open(store_root);
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(prepare(&root, &paths, &store));

    let mut bridge = None;
    root.remove_on_drop = false;
    let result: Result<(), PanicPayload> = AssertUnwindSafe(async {
        let login = crate::api::lifecycle_test_support::inert_login_controller(
            crate::login::LaunchAtLoginStatus::Unavailable,
        );
        bridge = Some(
            BridgeBuilder::new(engine.clone())
                .with_paths(paths.clone())
                .with_config_store(store.clone())
                .with_launch_at_login(login)
                .with_mouse_polling_enabled(false)
                .with_power_watching_enabled(false)
                .build()
                .expect("build the real bridge with the accepted synthetic facade"),
        );
        tokio::time::timeout(
            WATCHDOG,
            body(
                &root,
                &paths,
                &store,
                bridge.as_ref().expect("the real bridge was constructed"),
                &engine,
            ),
        )
        .await
        .expect("API/intent consumer exceeded the owned fixture watchdog");
    })
    .catch_unwind()
    .await;

    let mut cleanup_errors = Vec::new();
    if let Some(bridge) = bridge.take() {
        let shutdown = AssertUnwindSafe(tokio::time::timeout(
            WATCHDOG,
            crate::api::mounted_lifecycle::shutdown_and_drain(bridge),
        ))
        .catch_unwind()
        .await;
        match shutdown {
            Ok(Ok(Ok(()))) => {}
            Ok(Ok(Err(error))) => cleanup_errors.push(format!("shutdown failed: {error:?}")),
            Ok(Err(error)) => cleanup_errors.push(format!("shutdown watchdog expired: {error}")),
            Err(_) => cleanup_errors.push("shutdown panicked".to_owned()),
        }
    } else {
        cleanup_errors.push("bridge construction returned no owned drain handle".to_owned());
    }
    // No spawned helper, held operation, extra actor handle or bridge clone is
    // created by these scenarios. Drop the retained facade only after draining.
    drop(engine);
    drop(store);
    if cleanup_errors.is_empty() {
        root.remove_on_drop = true;
        if let Err(error) = root.remove_now() {
            cleanup_errors.push(format!("remove owned root {:?}: {error}", root.path));
        }
    } else {
        cleanup_errors.push(format!(
            "retained owned root {:?} because actor drain was not confirmed",
            root.path
        ));
    }
    if let Err(payload) = result {
        if !cleanup_errors.is_empty() {
            eprintln!("cleanup after API/intent assertion failure: {cleanup_errors:?}");
        }
        resume_unwind(payload);
    }
    assert!(cleanup_errors.is_empty(), "{cleanup_errors:?}");
}

fn physical_display(live_id: u32, secondary: bool) -> DisplaySnapshotEntry {
    let identity = DisplayIdentity {
        uuid: Some(format!("consumer-panel-{live_id}-7cd1")),
        vendor_id: Some(0x6ab4),
        model_id: Some(if secondary { 43 } else { 42 }),
        serial_number: Some(live_id + 8000),
        unit_number: Some(u32::from(secondary)),
        name: Some(if secondary { "Copper Annex" } else { "Copper Main" }.to_owned()),
    };
    let desc = DisplayDesc::with_identity(
        live_id,
        identity.clone(),
        if secondary { 2560 } else { 0 },
        0,
        2560,
        1440,
        1.0,
    )
    .with_refresh_rate(if secondary { 120 } else { 75 });
    DisplaySnapshotEntry {
        identity,
        desc,
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: false,
        assignment: None,
    }
}

fn numeric_display(live_id: u32) -> DisplaySnapshotEntry {
    // Weak identity is deliberate only for the saved LiveDisplayId lifecycle
    // contracts. Projection scenarios above retain meaningful strong identity.
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc: DisplayDesc::new(live_id, 0, 0, 1920, 1080, 1.0).with_refresh_rate(60),
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: false,
        assignment: None,
    }
}

fn write_project(
    root: &OwnedRoot,
    paths: &BridgePaths,
    id: &str,
    title: &str,
    kind: &str,
) -> PathBuf {
    let project = root.checked(paths.project_json(id));
    let directory = root.checked(project.parent().expect("project has an owned parent").to_path_buf());
    fs::create_dir_all(&directory).expect("create the owned workshop entry");
    let json = serde_json::json!({
        "title": title,
        "type": kind,
        "general": { "properties": {} }
    });
    fs::write(&project, serde_json::to_vec(&json).expect("encode fresh project input"))
        .expect("write the checked project.json");
    project
}

fn save_owner(
    root: &OwnedRoot,
    store: &ConfigStore,
    id: &str,
    selector: SerializedSelector,
) {
    root.checked(store.root().join("config.toml"));
    root.checked(store.root().join("wallpapers"));
    root.checked(store.root().join("wallpapers").join(format!("{id}.json")));
    let mut app = AppConfig::default();
    app.general.last_selected_wallpaper = Some(id.to_owned());
    app.monitors = vec![MonitorCfg {
        selector: selector.clone(),
        wallpaper: Some(id.to_owned()),
        ..MonitorCfg::default()
    }];
    let mut wallpaper = WallpaperConfig::new_for(id, "scene");
    wallpaper.monitors = vec![MonitorRender {
        selector,
        ..MonitorRender::default()
    }];
    store.save_app_config(&app).expect("save the actual configured app before building");
    store.save_wallpaper(&wallpaper).expect("save the actual owner configuration before building");
    assert_eq!(store.load().expect("read saved app").config, app);
    assert_eq!(store.load_wallpaper(id).expect("read saved wallpaper"), wallpaper);
}

fn assert_unknown_id(error: BridgeError, requested: &str) {
    assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
    assert!(
        error.message().contains(requested),
        "the InvalidInput must retain the requested opaque ID {requested:?}: {error:?}"
    );
}

fn assert_primary_monitor(
    snapshot: &BridgeMonitorInformationSnapshot,
    display: &DisplaySnapshotEntry,
    owner: &str,
    library_title: &str,
    scaling_label: &str,
    effective_fps: u32,
    audio_response: bool,
) {
    assert_eq!(snapshot.rows.len(), 1, "only the configured Primary is a monitor-information member");
    let row = &snapshot.rows[0];
    assert_eq!(row.display_id, "primary");
    assert_eq!(row.wallpaper_id, owner);
    assert_eq!(row.wallpaper_title, library_title);
    assert_eq!(
        row.title,
        display.title_with_suffix(&format!("({} - Primary - {owner})", display.desc.display_id)),
    );
    assert_eq!(row.mirror_target_display_id, None);
    assert_eq!(row.mirror_target_title, None);
    assert_eq!(row.scaling_mode, scaling_label);
    assert_eq!(row.target_fps, effective_fps.to_string());
    assert_eq!(row.audio_response, audio_response);
}

fn assert_discovered_owner(
    bundle: &BridgeSnapshotBundle,
    display: &DisplaySnapshotEntry,
    owner: &str,
    library_title: &str,
) {
    assert_eq!(bundle.settings.displays.len(), 1);
    let settings = &bundle.settings.displays[0];
    assert_eq!(settings.display_id, "primary");
    assert!(settings.enabled);
    assert_eq!(settings.mode, BridgeDisplayMode::Standalone);
    assert_eq!(settings.title, display.title_with_role(true));
    assert_eq!(bundle.app.active_wallpaper_ids, vec![owner.to_owned()]);
    assert_eq!(bundle.monitor_information.rows.len(), 1);
    let monitor = &bundle.monitor_information.rows[0];
    assert_eq!(monitor.display_id, "primary");
    assert_eq!(monitor.wallpaper_id, owner);
    assert_eq!(monitor.wallpaper_title, library_title);
    assert_eq!(
        monitor.title,
        display.title_with_suffix(&format!("({} - Primary - {owner})", display.desc.display_id)),
    );
}

fn assert_one_matching_scene(
    engine: &FakeEngineFacade,
    display: &DisplaySnapshotEntry,
    project: &str,
) -> SceneDesc {
    let mut calls = engine.calls();
    assert_eq!(calls.len(), 1, "there is exactly one total reconcile");
    assert_eq!(calls[0].len(), 1, "the sole reconcile is a singleton");
    let scene = &calls[0][0];
    assert_eq!(scene.display, display.desc);
    assert_eq!(scene.scene_path, project);
    assert_eq!(engine.rendered_scenes(), calls[0]);
    calls.pop().expect("the checked singleton reconcile exists")
        .pop().expect("the checked singleton scene exists")
}

fn install_live_scene(engine: &FakeEngineFacade, mut display: DisplaySnapshotEntry, scene: &SceneDesc) -> DisplaySnapshotEntry {
    // FakeEngineFacade returns handle=index+1 but does not publish a native
    // snapshot. This deliberate synthetic live row is input to later refreshes.
    display.handle = Some(SceneHandle::new(1));
    display.assignment = Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(scene)));
    display.window_active = true;
    engine.set_snapshot(vec![display.clone()]);
    engine.set_snapshot_after_refresh(vec![display.clone()]);
    display
}

fn assert_raw_roles(
    settings: &BridgeSettingsSnapshot,
    primary: &DisplaySnapshotEntry,
    secondary: &DisplaySnapshotEntry,
) {
    let secondary_id = secondary.connected_selector().id();
    assert_ne!(secondary_id, "primary");
    let actual_ids: Vec<_> = settings.displays.iter().map(|row| row.display_id.as_str()).collect();
    let expected_ids = vec!["primary", secondary_id.as_str()];
    assert_eq!(actual_ids, expected_ids);
    let primary_row = settings.displays.iter().find(|row| row.display_id == "primary")
        .expect("the first physical display retains the Primary role");
    assert!(primary_row.enabled);
    assert_eq!(primary_row.mode, BridgeDisplayMode::Standalone);
    assert_eq!(primary_row.selected_mirror_target, None);
    assert_eq!(primary_row.title, primary.title_with_role(true));
    let secondary_row = settings.displays.iter().find(|row| row.display_id == secondary_id)
        .expect("the strong secondary retains its connected identity selector");
    assert!(secondary_row.enabled);
    assert_eq!(secondary_row.mode, BridgeDisplayMode::Mirror);
    assert_eq!(secondary_row.selected_mirror_target.as_deref(), Some("primary"));
    assert!(secondary_row.mirror_targets.iter().any(|target| target == "primary"));
    assert_eq!(secondary_row.title, secondary.title_with_role(false));
}

#[tokio::test]
async fn raw_live_assignments_expose_first_seen_roles_without_configured_monitor_owners() {
    // Boundaries 1 and 7: no saved monitor ownership and no prior configured
    // mutation. A renderer Direct/Mirror pair is not configured ownership.
    const PRIMARY_ID: u32 = 2401;
    const SECONDARY_ID: u32 = 2402;
    for mirror_target in [DisplaySelector::Primary, DisplaySelector::LiveDisplayId(PRIMARY_ID)] {
        // Each resolution branch starts in its own genuinely unconfigured
        // fixture, so a previously remembered target cannot mask the branch.
        with_intent_bridge(
            move |root, paths, _store| {
                let mut primary = physical_display(PRIMARY_ID, false);
                let mut secondary = physical_display(SECONDARY_ID, true);
                let project = write_project(root, paths, "40501", "Copper Tide", "scene");
                let scene = SceneDesc::new(
                    primary.desc.clone(),
                    project.to_string_lossy().into_owned(),
                    root.checked(paths.assets_root()).to_string_lossy().into_owned(),
                    75,
                    false,
                );
                scene.validate().expect("the raw Direct descriptor is valid");
                primary.handle = Some(SceneHandle::new(51));
                primary.window_active = true;
                primary.assignment = Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&scene)));
                secondary.handle = Some(SceneHandle::new(52));
                secondary.window_active = true;
                secondary.assignment = Some(WallpaperAssignment::Mirror(mirror_target));
                vec![primary, secondary]
            },
            |_root, _paths, _store, bridge, _engine| Box::pin(async move {
                let settings = bridge.settings_snapshot().await.expect("project raw live inventory through public settings");
                assert_raw_roles(&settings, &physical_display(PRIMARY_ID, false), &physical_display(SECONDARY_ID, true));
                let monitors = bridge.monitor_information_snapshot().await
                    .expect("read actual configured-active monitor information");
                assert!(monitors.rows.is_empty(), "renderer assignments alone must not invent configured-active monitor owners");
            }),
        ).await;
    }
}

#[tokio::test]
async fn first_saved_primary_projection_then_real_edits_keep_per_wallpaper_disabled_annex_visible() {
    const OWNER: &str = "40511";
    const TITLE: &str = "Saffron Current";
    with_intent_bridge(
        |root, paths, store| {
            write_project(root, paths, OWNER, TITLE, "scene");
            save_owner(root, store, OWNER, SerializedSelector::Primary);
            let secondary = physical_display(2512, true);
            // Missing first-seen records inherit Primary ownership. Persist an
            // explicit globally enabled, independently unassigned secondary.
            let mut app = store.load().expect("read the saved Primary ownership").config;
            app.monitors.push(MonitorCfg {
                selector: secondary.connected_selector(),
                enabled: true,
                mode: "independent".to_owned(),
                wallpaper: None,
                mirror_target: None,
            });
            root.checked(store.root().join("config.toml"));
            store.save_app_config(&app).expect("persist the explicit unassigned secondary before building");
            vec![physical_display(2511, false), secondary]
        },
        |_root, _paths, store, bridge, _engine| Box::pin(async move {
            let primary = physical_display(2511, false);
            let secondary = physical_display(2512, true);
            let secondary_id = secondary.connected_selector().id();
            bridge.refresh_library().await.expect("scan the saved owner's real project and library title");
            let selected = bridge.select_wallpaper(OWNER.to_owned()).await
                .expect("load the actual saved owner config without resetting it through injection");
            assert_eq!(selected.app.selected_wallpaper_id.as_deref(), Some(OWNER));

            // Boundary 8 is an initial configured projection, observed before
            // any option edit or Bootstrap. The unassigned secondary is absent
            // from monitor information even though it is globally connected.
            let initial = bridge.monitor_information_snapshot().await
                .expect("observe the first configured monitor projection");
            assert_primary_monitor(&initial, &primary, OWNER, TITLE, "Fill", 60, true);

            bridge.set_scaling_mode(OWNER.to_owned(), "primary".to_owned(), BridgeScalingMode::Match)
                .await.expect("perform the actual Primary scaling edit");
            bridge.set_target_fps(OWNER.to_owned(), "primary".to_owned(), 240)
                .await.expect("perform an actual above-refresh rate edit");
            bridge.set_audio_response_enabled(OWNER.to_owned(), false)
                .await.expect("perform the actual audio-response edit");
            bridge.apply_wallpaper_options(OWNER.to_owned(), true).await
                .expect("commit the edited owner through the real apply operation");

            // Boundary 2 specifically consumes monitor_information: effective
            // FPS must be decimal text, the scaling label is public Match, and
            // the configured singleton's actual audio response is now false.
            let monitors = bridge.monitor_information_snapshot().await
                .expect("read the edited monitor-information consumer");
            assert_primary_monitor(&monitors, &primary, OWNER, TITLE, "Match", 75, false);

            // Boundary 3: both displays stay globally enabled. The secondary
            // row is present in this owner's options but per-wallpaper disabled;
            // this is not global disablement, which would omit that row.
            let settings = bridge.settings_snapshot().await.expect("read global connected-display settings");
            assert_eq!(settings.displays.len(), 2);
            let mut settings_ids: Vec<_> = settings.displays.iter().map(|row| row.display_id.as_str()).collect();
            let mut expected_ids = vec!["primary", secondary_id.as_str()];
            settings_ids.sort_unstable();
            expected_ids.sort_unstable();
            assert_eq!(settings_ids, expected_ids);
            assert!(settings.displays.iter().all(|row| row.enabled));
            let options = bridge.wallpaper_options_snapshot(OWNER.to_owned()).await
                .expect("read actual selected-owner options");
            assert_eq!(options.wallpaper_id, OWNER);
            assert_eq!(options.title, TITLE);
            assert_eq!(options.display_configurations.len(), 2);
            let mut option_ids: Vec<_> = options.display_configurations.iter().map(|row| row.display_id.as_str()).collect();
            option_ids.sort_unstable();
            assert_eq!(option_ids, expected_ids);
            let primary_options = options.display_configurations.iter().find(|row| row.display_id == "primary")
                .expect("the selected owner has its Primary options row");
            assert!(primary_options.enabled);
            assert_eq!(primary_options.title, primary.title_with_role(true));
            assert_eq!(primary_options.scaling_mode, BridgeScalingMode::Match);
            assert_eq!(primary_options.target_fps, 75);
            assert_eq!(primary_options.max_fps, 75);
            let secondary_options = options.display_configurations.iter().find(|row| row.display_id == secondary_id)
                .expect("the globally enabled annex is still an options member");
            assert!(!secondary_options.enabled);
            assert_eq!(secondary_options.title, secondary.title_with_role(false));
            assert!(!options.audio_response_enabled);

            let saved = store.load_wallpaper(OWNER).expect("the real store retained the applied edits");
            assert!(!saved.audio.response_enabled);
            let connected = [primary, secondary];
            let saved_primary = saved.monitors.iter().find(|monitor|
                monitor.selector.to_selector().matches_primary(&connected[0], &connected)
            ).expect("the saved owner retains the render record for the actual Primary");
            assert_eq!(saved_primary.parse_scaling_mode(), wallpaper_core::project::ScalingMode::Fit);
            assert_eq!(saved_primary.fps_on(75), 75);
        }),
    ).await;
}

fn assert_mixed_inventory(library: &BridgeLibrarySnapshot) {
    assert_eq!(
        (library.scene_count, library.video_count, library.webpage_count, library.unknown_count),
        (1, 1, 1, 1),
    );
    assert_eq!(library.wallpapers.len(), 4);
    let mut actual: Vec<_> = library.wallpapers.iter().map(|entry| (
        entry.id.as_str(), entry.title.as_str(), entry.kind,
    )).collect();
    actual.sort_unstable_by(|left, right| left.0.cmp(right.0));
    assert_eq!(actual, vec![
        ("40601", "Copper Tide", BridgeWallpaperKind::ProjectScene),
        ("40602", "Amber Spool", BridgeWallpaperKind::Video),
        ("40603", "Cobalt Window", BridgeWallpaperKind::Webpage),
        ("40604", "Unclassified Nebula", BridgeWallpaperKind::Unknown),
    ]);
}

#[tokio::test]
async fn one_public_mixed_inventory_retains_a_valid_selection_across_contextual_unknown_id_errors() {
    const SELECTED: &str = "40601";
    const UNKNOWN_SELECTION: &str = "opaque-missing-selection-c91d";
    const UNKNOWN_OPTIONS: &str = "opaque-missing-options-2ef8";
    with_intent_bridge(
        |root, paths, _store| {
            write_project(root, paths, "40601", "Copper Tide", "scene");
            write_project(root, paths, "40602", "Amber Spool", "video");
            write_project(root, paths, "40603", "Cobalt Window", "web");
            write_project(root, paths, "40604", "Unclassified Nebula", "application");
            Vec::new()
        },
        |_root, _paths, _store, bridge, _engine| Box::pin(async move {
            // Boundary 4 observes counts and full membership from the same real
            // scan/public library, rather than a separate type-filter object.
            bridge.refresh_library().await.expect("scan the four owned project entries");
            for kind in [
                BridgeWallpaperKind::ProjectScene,
                BridgeWallpaperKind::Video,
                BridgeWallpaperKind::Webpage,
                BridgeWallpaperKind::Unknown,
            ] {
                bridge.set_filter(kind, true).await.expect("make every real library kind publicly visible");
            }
            let library = bridge.library_snapshot().await.expect("read that same actual public inventory");
            assert_mixed_inventory(&library);

            // Boundary 5 first establishes a successful real selection, then
            // checks the error's kind/opaque-ID context and both public owners
            // of selection state. No English error sentence is pinned.
            let selected = bridge.select_wallpaper(SELECTED.to_owned()).await
                .expect("select the existing scene through the actual API");
            assert_eq!(selected.app.selected_wallpaper_id.as_deref(), Some(SELECTED));
            let error = bridge.select_wallpaper(UNKNOWN_SELECTION.to_owned()).await
                .expect_err("an unknown public selection must fail");
            assert_unknown_id(error, UNKNOWN_SELECTION);
            let app = bridge.app_snapshot().await.expect("read selection after the rejected request");
            assert_eq!(app.selected_wallpaper_id.as_deref(), Some(SELECTED));
            let library = bridge.library_snapshot().await.expect("read consistent public library selection");
            assert_mixed_inventory(&library);
            let selected_ids: Vec<_> = library.wallpapers.iter().filter(|entry| entry.selected)
                .map(|entry| entry.id.as_str()).collect();
            assert_eq!(selected_ids, vec![SELECTED]);

            // Boundary 6 exercises the actual options request independently of
            // selection, with a different requested opaque missing ID.
            let error = bridge.wallpaper_options_snapshot(UNKNOWN_OPTIONS.to_owned()).await
                .expect_err("unknown public options must fail");
            assert_unknown_id(error, UNKNOWN_OPTIONS);
        }),
    ).await;
}

#[tokio::test]
async fn bootstrap_discovers_a_saved_numeric_owner_with_one_singleton_reconcile() {
    const OWNER: &str = "40701";
    const TITLE: &str = "Porcelain Orbit";
    with_intent_bridge(
        |root, paths, store| {
            write_project(root, paths, OWNER, TITLE, "scene");
            save_owner(root, store, OWNER, SerializedSelector::LiveDisplayId { display_id: 2701 });
            Vec::new()
        },
        |root, paths, _store, bridge, engine| Box::pin(async move {
            let display = numeric_display(2701);
            let project = root.checked(paths.project_json(OWNER)).to_string_lossy().into_owned();
            assert!(engine.calls().is_empty(), "builder assembly is not a reconcile");
            assert!(engine.display_snapshot().is_empty(), "the Bootstrap-discovered display was previously absent");
            // Boundary 9: only the real Bootstrap refresh discovers this row.
            // The saved app, not an injected active-ID list, owns the wallpaper.
            engine.set_snapshot_after_refresh(vec![display.clone()]);
            let bootstrapped = bridge.bootstrap().await.expect("Bootstrap discovers the configured numeric display");
            assert_discovered_owner(&bootstrapped, &display, OWNER, TITLE);
            let settings = bridge.settings_snapshot().await.expect("observe the discovered public settings endpoint");
            assert_eq!(settings.displays.len(), 1);
            assert_eq!(settings.displays[0].display_id, "primary");
            assert!(settings.displays[0].enabled);
            let app = bridge.app_snapshot().await.expect("observe the configured active owner endpoint");
            assert_eq!(app.active_wallpaper_ids, vec![OWNER.to_owned()]);
            assert_one_matching_scene(engine, &display, &project);
        }),
    ).await;
}

#[tokio::test]
async fn explicit_refresh_discovers_once_and_keeps_existing_even_window_inactive_scenes() {
    const OWNER: &str = "40711";
    const TITLE: &str = "Juniper Signal";
    with_intent_bridge(
        |root, paths, store| {
            write_project(root, paths, OWNER, TITLE, "scene");
            save_owner(root, store, OWNER, SerializedSelector::LiveDisplayId { display_id: 2711 });
            Vec::new()
        },
        |root, paths, _store, bridge, engine| Box::pin(async move {
            let display = numeric_display(2711);
            let project = root.checked(paths.project_json(OWNER)).to_string_lossy().into_owned();
            // Load real scanned metadata and the actual saved wallpaper config
            // without Bootstrap, without a display refresh, and without injection.
            bridge.refresh_library().await.expect("scan before explicit display discovery");
            bridge.select_wallpaper(OWNER.to_owned()).await.expect("load this saved owner through SelectWallpaper");
            assert!(engine.calls().is_empty(), "library/selection setup must not reconstruct a scene");
            assert!(engine.display_snapshot().is_empty(), "no configured display has appeared before the first explicit refresh");

            // Boundary 10: the first explicit RefreshDisplays is the discovery
            // route and accounts for exactly one total singleton reconcile.
            engine.set_snapshot_after_refresh(vec![display.clone()]);
            let discovered = bridge.refresh_displays().await.expect("first explicit RefreshDisplays discovers the saved owner");
            assert_discovered_owner(&discovered, &display, OWNER, TITLE);
            let requested = assert_one_matching_scene(engine, &display, &project);

            // Boundary 11 supplies the coherent synthetic handle/assignment that
            // this accepted fake intentionally does not publish automatically.
            // Updating both ports prevents a later refresh restoring stale rows.
            let live = install_live_scene(engine, display.clone(), &requested);
            let unchanged = bridge.refresh_displays().await.expect("refresh an existing live scene");
            assert_discovered_owner(&unchanged, &display, OWNER, TITLE);
            assert_one_matching_scene(engine, &display, &project);
            assert_eq!(engine.display_snapshot(), vec![live.clone()]);

            // Boundary 12 changes ONLY window_active. Retain the exact handle
            // and Direct assignment rather than exercising a missing-scene path.
            let mut inactive = live.clone();
            inactive.window_active = false;
            assert_eq!(inactive.handle, live.handle);
            assert_eq!(inactive.assignment, live.assignment);
            assert_ne!(inactive.window_active, live.window_active);
            engine.set_snapshot(vec![inactive.clone()]);
            engine.set_snapshot_after_refresh(vec![inactive.clone()]);
            let inactive_refresh = bridge.refresh_displays().await
                .expect("window inactivity alone must not reconstruct the existing scene");
            assert_discovered_owner(&inactive_refresh, &display, OWNER, TITLE);
            assert_one_matching_scene(engine, &display, &project);
            assert_eq!(engine.display_snapshot(), vec![inactive]);
        }),
    ).await;
}

#[tokio::test]
async fn initially_absent_saved_numeric_owner_stays_published_then_reconstructs_once_on_appearance() {
    const OWNER: &str = "40721";
    const TITLE: &str = "Indigo Meridian";
    with_intent_bridge(
        |root, paths, store| {
            write_project(root, paths, OWNER, TITLE, "scene");
            save_owner(root, store, OWNER, SerializedSelector::LiveDisplayId { display_id: 2721 });
            Vec::new()
        },
        |root, paths, _store, bridge, engine| Box::pin(async move {
            let display = numeric_display(2721);
            let project = root.checked(paths.project_json(OWNER)).to_string_lossy().into_owned();
            assert!(engine.display_snapshot().is_empty());
            // Boundary 13 begins with genuine initial absence: no prior live
            // handle, successful reconcile or configured-scene publication.
            let absent = bridge.bootstrap().await.expect("Bootstrap while the configured numeric display is initially absent");
            assert_eq!(absent.app.active_wallpaper_ids, vec![OWNER.to_owned()]);
            assert!(absent.monitor_information.rows.is_empty());
            assert!(engine.calls().is_empty());
            assert!(engine.rendered_scenes().is_empty());

            // Boundary 14 independently observes this endpoint BEFORE any
            // appearance. Configured ownership is retained; it does not imply
            // either a native scene or a synthetic reconcile ever existed.
            let absent_app = bridge.app_snapshot().await.expect("observe the initial-absence endpoint itself");
            assert_eq!(absent_app.active_wallpaper_ids, vec![OWNER.to_owned()]);
            assert!(engine.calls().is_empty());
            assert!(engine.rendered_scenes().is_empty());

            engine.set_snapshot_after_refresh(vec![display.clone()]);
            let appeared = bridge.refresh_displays().await.expect("the initially absent numeric display now appears");
            assert_discovered_owner(&appeared, &display, OWNER, TITLE);
            let appeared_app = bridge.app_snapshot().await.expect("observe the same configured owner after appearance");
            assert_eq!(appeared_app.active_wallpaper_ids, absent_app.active_wallpaper_ids);
            assert_one_matching_scene(engine, &display, &project);
        }),
    ).await;
}
