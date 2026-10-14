use std::collections::{BTreeMap, BTreeSet};

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySelector, DisplaySnapshotEntry,
    project::{ScalingMode, SceneFraming},
};

use crate::{
    api::{BridgeWallpaperEntry, BridgeWallpaperKind},
    config::{
        AppConfig, FramingCfg, MonitorCfg, MonitorRender, MonitorSettingsCfg, SerializedSelector,
        WallpaperConfig,
    },
    engine::{ActivationInputs, NativeVideoRejection},
    paths::BridgePaths,
};

fn assert_f32_close(actual: f32, expected: f32) {
    assert!(
        (actual - expected).abs() <= f32::EPSILON,
        "expected {actual} to be within f32::EPSILON of {expected}"
    );
}

#[test]
fn activation_plan_marks_scenes_paused_when_global_playback_is_paused() {
    let mut config = AppConfig::default();
    config.monitors.push(MonitorCfg {
        selector: SerializedSelector::Primary,
        enabled: true,
        mode: "independent".to_string(),
        wallpaper: Some("100".to_string()),
        mirror_target: None,
    });
    let mut wallpapers = BTreeMap::new();
    wallpapers.insert("100".to_string(), WallpaperConfig::new_for("100", "scene"));
    let display = DisplayDesc::with_identity(1, DisplayIdentity::default(), 0, 0, 1920, 1080, 2.0);
    let displays = vec![DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc: display,
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }];
    let paths = BridgePaths::for_home("/Users/example");

    let scenes = ActivationInputs {
        app_config: &config,
        wallpapers: &wallpapers,
        library: None,
        displays: &displays,
        suspended_displays: &BTreeSet::new(),
        held: &BTreeSet::new(),
        paused: true,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
        frame_rate_cap: None,
        audio_suppressed: false,
    }
    .build()
    .unwrap();

    assert_eq!(scenes.len(), 1);
    assert!(scenes[0].paused);
}

#[test]
fn activation_plan_leaves_display_empty_when_assigned_wallpaper_left_the_library() {
    // A wallpaper deleted while its display was disconnected keeps its
    // assignment. Planning a scene for it would fail the whole reconcile and
    // block applying anything to any other display.
    let display_a = identified_display("a", 1);
    let display_b = identified_display("b", 3);
    let mut config = AppConfig::default();
    for (display, wallpaper) in [(&display_a, "100"), (&display_b, "gone")] {
        config.monitors.push(MonitorCfg {
            selector: SerializedSelector::from_selector(&DisplaySelector::Identity(
                display.identity.clone(),
            )),
            enabled: true,
            mode: "independent".to_string(),
            wallpaper: Some(wallpaper.to_string()),
            mirror_target: None,
        });
    }
    let mut wallpapers = BTreeMap::new();
    for id in ["100", "gone"] {
        wallpapers.insert(id.to_string(), WallpaperConfig::new_for(id, "scene"));
    }
    let mut library = installed(&wallpapers);
    library.retain(|entry| entry.id != "gone");
    let displays = vec![display_a, display_b];
    let paths = BridgePaths::for_home("/Users/example");

    let scenes = ActivationInputs {
        app_config: &config,
        wallpapers: &wallpapers,
        library: Some(&library),
        displays: &displays,
        suspended_displays: &BTreeSet::new(),
        held: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
        frame_rate_cap: None,
        audio_suppressed: false,
    }
    .build()
    .unwrap();

    assert_eq!(scenes.len(), 1);
    assert_scene(&scenes, 1, "100");
}

#[test]
fn activation_plan_gives_primary_wallpaper_to_current_primary_display() {
    let display_a = identified_display("a", 1);
    let display_b = identified_display("b", 3);
    let selector_a =
        SerializedSelector::from_selector(&DisplaySelector::Identity(display_a.identity.clone()));
    let selector_b =
        SerializedSelector::from_selector(&DisplaySelector::Identity(display_b.identity.clone()));
    let mut config = AppConfig::default();
    config.monitors.push(MonitorCfg {
        selector: selector_a,
        enabled: true,
        mode: "independent".to_string(),
        wallpaper: Some("100".to_string()),
        mirror_target: None,
    });
    config.monitors.push(MonitorCfg {
        selector: selector_b,
        enabled: true,
        mode: "independent".to_string(),
        wallpaper: Some("200".to_string()),
        mirror_target: None,
    });
    config.monitors.push(MonitorCfg {
        selector: SerializedSelector::Primary,
        enabled: true,
        mode: "independent".to_string(),
        wallpaper: Some("300".to_string()),
        mirror_target: None,
    });
    let mut wallpapers = BTreeMap::new();
    for id in ["100", "200", "300"] {
        wallpapers.insert(id.to_string(), WallpaperConfig::new_for(id, "scene"));
    }

    let displays = vec![display_a.clone(), display_b.clone()];
    let paths = BridgePaths::for_home("/Users/example");
    let scenes = ActivationInputs {
        app_config: &config,
        wallpapers: &wallpapers,
        library: None,
        displays: &displays,
        suspended_displays: &BTreeSet::new(),
        held: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
        frame_rate_cap: None,
        audio_suppressed: false,
    }
    .build()
    .unwrap();
    assert_eq!(scenes.len(), 2);
    assert_scene(&scenes, 1, "300");
    assert_scene(&scenes, 3, "200");

    let displays = vec![display_b, display_a];
    let scenes = ActivationInputs {
        app_config: &config,
        wallpapers: &wallpapers,
        library: None,
        displays: &displays,
        suspended_displays: &BTreeSet::new(),
        held: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
        frame_rate_cap: None,
        audio_suppressed: false,
    }
    .build()
    .unwrap();
    assert_eq!(scenes.len(), 2);
    assert_scene(&scenes, 3, "300");
    assert_scene(&scenes, 1, "100");
}

#[test]
fn activation_plan_uses_primary_render_override_for_identity_primary_monitor() {
    let display = identified_display("primary", 1);
    let identity_selector =
        SerializedSelector::from_selector(&DisplaySelector::Identity(display.identity.clone()));
    let app_config = AppConfig {
        monitors: vec![MonitorCfg {
            selector: identity_selector,
            enabled: true,
            mode: "independent".to_string(),
            wallpaper: Some("3539559752".to_string()),
            mirror_target: None,
        }],
        ..AppConfig::default()
    };
    let mut wallpaper = WallpaperConfig::new_for("3539559752", "scene");
    wallpaper.monitors.push(MonitorRender {
        selector: SerializedSelector::Primary,
        scaling_mode: "fill".to_string(),
        ..MonitorRender::default()
    });
    let wallpapers = BTreeMap::from([("3539559752".to_string(), wallpaper)]);
    let paths = BridgePaths::for_home("/Users/example");

    let scenes = ActivationInputs {
        app_config: &app_config,
        wallpapers: &wallpapers,
        library: None,
        displays: &[display],
        suspended_displays: &BTreeSet::new(),
        held: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
        frame_rate_cap: None,
        audio_suppressed: false,
    }
    .build()
    .unwrap();

    assert_eq!(scenes.len(), 1);
    assert_eq!(
        scenes[0].scaling_mode,
        ScalingMode::Fill,
        "a single-monitor identity assignment must still inherit the saved Primary render override"
    );
}

#[test]
fn activation_plan_uses_identity_render_override_for_primary_monitor() {
    let display = identified_display("primary", 1);
    let identity_selector =
        SerializedSelector::from_selector(&DisplaySelector::Identity(display.identity.clone()));
    let app_config = AppConfig {
        monitors: vec![MonitorCfg {
            selector: SerializedSelector::Primary,
            enabled: true,
            mode: "independent".to_string(),
            wallpaper: Some("3539559752".to_string()),
            mirror_target: None,
        }],
        ..AppConfig::default()
    };
    let mut wallpaper = WallpaperConfig::new_for("3539559752", "scene");
    wallpaper.monitors.push(MonitorRender {
        selector: identity_selector,
        scaling_mode: "fill".to_string(),
        ..MonitorRender::default()
    });
    let wallpapers = BTreeMap::from([("3539559752".to_string(), wallpaper)]);
    let paths = BridgePaths::for_home("/Users/example");

    let scenes = ActivationInputs {
        app_config: &app_config,
        wallpapers: &wallpapers,
        library: None,
        displays: &[display],
        suspended_displays: &BTreeSet::new(),
        held: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
        frame_rate_cap: None,
        audio_suppressed: false,
    }
    .build()
    .unwrap();

    assert_eq!(scenes.len(), 1);
    assert_eq!(
        scenes[0].scaling_mode,
        ScalingMode::Fill,
        "a Primary assignment must inherit the saved identity render override for the same \
         primary display"
    );
}

/// Library entries for every configured wallpaper, so the plan treats them as installed.
fn installed(wallpapers: &BTreeMap<String, WallpaperConfig>) -> Vec<BridgeWallpaperEntry> {
    wallpapers
        .keys()
        .map(|id| BridgeWallpaperEntry {
            id: id.clone(),
            title: id.clone(),
            kind: BridgeWallpaperKind::ProjectScene,
            supported: true,
            active: false,
            selected: false,
            preview_path: None,
        })
        .collect()
}

fn assert_scene(scenes: &[wallpaper_core::project::SceneDesc], display_id: u32, workshop_id: &str) {
    let scene = scenes
        .iter()
        .find(|scene| scene.display.display_id == display_id)
        .unwrap_or_else(|| panic!("missing scene for display {display_id}"));
    assert!(
        scene.scene_path.contains(&format!("/{workshop_id}/")),
        "display {display_id} should use wallpaper {workshop_id}, got {}",
        scene.scene_path
    );
}

#[test]
fn mirror_scene_follows_source_wallpaper_with_monitor_overrides() {
    let mut wallpapers = BTreeMap::new();
    let mut wallpaper = WallpaperConfig::new_for("100", "scene");
    wallpaper.audio.response_enabled = true;
    wallpaper.audio.volume = 0.4;
    wallpaper.audio.muted = false;
    wallpapers.insert("100".to_string(), wallpaper);
    let app_config = AppConfig {
        monitors: vec![
            MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                wallpaper: Some("100".to_string()),
                ..MonitorCfg::default()
            },
            MonitorCfg {
                selector: SerializedSelector::LiveDisplayId { display_id: 2 },
                enabled: true,
                mode: "mirror".to_string(),
                mirror_target: Some(SerializedSelector::Primary),
                ..MonitorCfg::default()
            },
        ],
        monitor_settings: vec![MonitorSettingsCfg {
            selector: SerializedSelector::LiveDisplayId { display_id: 2 },
            scaling_mode: "fill".to_string(),
            scaling_factor: 1.25,
            frame_rate: Some(30),
            volume: 0.2,
            muted: true,
        }],
        ..AppConfig::default()
    };
    let displays = vec![display_snapshot(1), display_snapshot(2)];
    let paths = BridgePaths::for_home("/tmp/test-home");

    let scenes = ActivationInputs {
        app_config: &app_config,
        wallpapers: &wallpapers,
        library: None,
        displays: &displays,
        suspended_displays: &BTreeSet::new(),
        held: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
        frame_rate_cap: None,
        audio_suppressed: false,
    }
    .build()
    .unwrap();

    let primary = scenes
        .iter()
        .find(|scene| scene.display.display_id == 1)
        .expect("primary scene should be active");
    let mirror = scenes
        .iter()
        .find(|scene| scene.display.display_id == 2)
        .expect("mirror scene should be active");
    assert_eq!(scenes.len(), 2);
    assert!(primary.audio_response_enabled);
    assert!(mirror.audio_response_enabled);
    assert_f32_close(f32::from(primary.audio_volume), 0.4);
    assert_f32_close(f32::from(mirror.audio_volume), 0.2);
    assert!(!primary.audio_muted);
    assert!(mirror.audio_muted);
    assert_eq!(
        mirror.scaling_mode,
        wallpaper_core::project::ScalingMode::Fill
    );
    assert!(
        (mirror.scaling_factor - 1.25).abs() <= f64::EPSILON,
        "expected {} to be within f64::EPSILON of 1.25",
        mirror.scaling_factor
    );
    assert_eq!(mirror.fps, 30);
    assert_scene(&scenes, 2, "100");
}

fn identified_display(uuid: &str, display_id: u32) -> DisplaySnapshotEntry {
    let identity = DisplayIdentity {
        uuid: Some(uuid.to_string()),
        vendor_id: Some(10),
        model_id: Some(display_id),
        serial_number: Some(100 + display_id),
        unit_number: Some(display_id),
        name: Some(format!("Display {uuid}")),
    };
    DisplaySnapshotEntry {
        identity: identity.clone(),
        desc: DisplayDesc::with_identity(display_id, identity, 0, 0, 1920, 1080, 2.0),
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

fn display_snapshot(display_id: u32) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc: DisplayDesc::with_identity(
            display_id,
            DisplayIdentity::default(),
            0,
            0,
            1920,
            1080,
            2.0,
        ),
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

/// The routing rules themselves, with no actor and no host query in the way.
///
/// Every reconcile runs through `build()`/`build_native_video()`, including the
/// ones the bridge spawns for unrelated reasons, so a recorded refusal has to
/// be re-evaluated here rather than only in the bookkeeping that runs when the
/// host asks what to play. Otherwise a wallpaper whose configuration changed
/// would be rendered by both backends until the host happened to ask again.
#[test]
fn a_rejection_recorded_for_another_admission_key_does_not_route_a_video_to_the_engine() {
    let temp = tempfile::tempdir().unwrap();
    let paths = BridgePaths::for_home(temp.path().to_path_buf());
    let project_dir = paths.steam_workshop_root().join("500");
    std::fs::create_dir_all(&project_dir).unwrap();
    std::fs::write(project_dir.join("clip.mp4"), b"clip bytes").unwrap();

    let mut config = AppConfig::default();
    config.monitors.push(MonitorCfg {
        selector: SerializedSelector::Primary,
        enabled: true,
        mode: "independent".to_string(),
        wallpaper: Some("500".to_string()),
        mirror_target: None,
    });
    let mut wallpapers = BTreeMap::new();
    wallpapers.insert("500".to_string(), WallpaperConfig::new_for("500", "video"));
    let mut project_models = BTreeMap::new();
    project_models.insert(
        "500".to_string(),
        crate::project::ProjectModel::parse(
            "500",
            r#"{"type":"video","title":"Clip","file":"clip.mp4","description":""}"#,
        )
        .unwrap(),
    );
    let displays = vec![display_snapshot(1)];
    let suspended = BTreeSet::new();

    fn plan<'a>(
        app_config: &'a AppConfig,
        wallpapers: &'a BTreeMap<String, WallpaperConfig>,
        displays: &'a [DisplaySnapshotEntry],
        suspended_displays: &'a BTreeSet<u32>,
        paths: &'a BridgePaths,
        project_models: &'a BTreeMap<String, crate::project::ProjectModel>,
        native_video_rejected: &'a crate::engine::NativeVideoRejections,
    ) -> ActivationInputs<'a> {
        ActivationInputs {
            app_config,
            wallpapers,
            library: None,
            displays,
            suspended_displays,
            paused: false,
            paths,
            force_shader_refresh: false,
            project_models,
            native_video_enabled: true,
            native_video_rejected,
            frame_rate_cap: None,
            audio_suppressed: false,
            held: &NONE_HELD,
        }
    }
    static NONE_HELD: BTreeSet<String> = BTreeSet::new();
    macro_rules! inputs {
        ($rejected:expr) => {
            plan(
                &config,
                &wallpapers,
                &displays,
                &suspended,
                &paths,
                &project_models,
                $rejected,
            )
        };
    }

    let empty = BTreeMap::new();
    let live_key = inputs!(&empty).build_native_video().unwrap()[0].admission_key;

    let matching: crate::engine::NativeVideoRejections = [(
        "500".to_string(),
        [(
            live_key,
            NativeVideoRejection {
                reason: "unsupported".to_string(),
            },
        )]
        .into(),
    )]
    .into();
    assert!(inputs!(&matching).build_native_video().unwrap().is_empty());
    assert_eq!(
        inputs!(&matching).build().unwrap().len(),
        1,
        "a refusal that describes the live configuration puts the wallpaper on the engine"
    );

    let stale: crate::engine::NativeVideoRejections = [(
        "500".to_string(),
        [(
            live_key ^ 1,
            NativeVideoRejection {
                reason: "unsupported".to_string(),
            },
        )]
        .into(),
    )]
    .into();
    assert_eq!(
        inputs!(&stale).build_native_video().unwrap().len(),
        1,
        "a refusal for a configuration that no longer exists must not exclude this one"
    );
    assert!(
        inputs!(&stale).build().unwrap().is_empty(),
        "and the engine must not also be handed a scene for it"
    );
}
fn independent(display_id: u32, wallpaper: &str) -> MonitorCfg {
    MonitorCfg {
        selector: SerializedSelector::LiveDisplayId { display_id },
        enabled: true,
        mode: "independent".to_string(),
        wallpaper: Some(wallpaper.to_string()),
        mirror_target: None,
    }
}

/// A scene wallpaper, a web page and a plain video on three displays, with the
/// video's file on disk so the native player would take it.
struct HeldFixture {
    _home: tempfile::TempDir,
    paths: BridgePaths,
    config: AppConfig,
    wallpapers: BTreeMap<String, WallpaperConfig>,
    models: BTreeMap<String, crate::project::ProjectModel>,
    displays: Vec<DisplaySnapshotEntry>,
    suspended: BTreeSet<u32>,
    rejected: crate::engine::NativeVideoRejections,
}

impl HeldFixture {
    fn new() -> Self {
        let home = tempfile::tempdir().unwrap();
        let paths = BridgePaths::for_home(home.path().to_path_buf());
        let clip = paths.steam_workshop_root().join("500");
        std::fs::create_dir_all(&clip).unwrap();
        std::fs::write(clip.join("clip.mp4"), b"clip bytes").unwrap();
        let config = AppConfig {
            monitors: vec![
                independent(1, "100"),
                independent(2, "300"),
                independent(3, "500"),
            ],
            ..AppConfig::default()
        };
        let wallpapers = [("100", "scene"), ("300", "web"), ("500", "video")]
            .into_iter()
            .map(|(id, kind)| (id.to_string(), WallpaperConfig::new_for(id, kind)))
            .collect();
        let models = [
            ("300", r#"{"type":"web","title":"Page","file":"index.html"}"#),
            ("500", r#"{"type":"video","title":"Clip","file":"clip.mp4"}"#),
        ]
        .into_iter()
        .map(|(id, manifest)| {
            (id.to_string(), crate::project::ProjectModel::parse(id, manifest).unwrap())
        })
        .collect();
        Self {
            _home: home,
            paths,
            config,
            wallpapers,
            models,
            displays: vec![display_snapshot(1), display_snapshot(2), display_snapshot(3)],
            suspended: BTreeSet::new(),
            rejected: BTreeMap::new(),
        }
    }

    fn inputs<'a>(&'a self, held: &'a BTreeSet<String>) -> ActivationInputs<'a> {
        ActivationInputs {
            app_config: &self.config,
            wallpapers: &self.wallpapers,
            library: None,
            displays: &self.displays,
            suspended_displays: &self.suspended,
            paused: false,
            paths: &self.paths,
            force_shader_refresh: false,
            project_models: &self.models,
            native_video_enabled: true,
            native_video_rejected: &self.rejected,
            frame_rate_cap: None,
            audio_suppressed: false,
            held,
        }
    }
}

/// Three renderers, one rule: a wallpaper the load journal holds back is
/// offered to none of them, so a stale routing decision can never hand a held
/// page or clip to the host while the engine skips only the scenes.
#[test]
fn held_wallpaper_gets_no_scene_web_or_native_video_descriptor() {
    let fixture = HeldFixture::new();
    let none = BTreeSet::new();
    let baseline = fixture.inputs(&none);
    assert_eq!(baseline.build().unwrap().len(), 1);
    assert_eq!(baseline.build_web().unwrap().len(), 1);
    assert_eq!(baseline.build_native_video().unwrap().len(), 1);

    let all: BTreeSet<String> = ["100", "300", "500"].map(String::from).into();
    let held = fixture.inputs(&all);
    assert!(held.build().unwrap().is_empty());
    assert!(held.build_web().unwrap().is_empty());
    assert!(held.build_native_video().unwrap().is_empty());
    assert!(
        held.render_backends().videos.is_empty(),
        "what is reported as playing must follow what is planned"
    );

    // The hold belongs to one wallpaper; the others on screen are untouched.
    let only_page: BTreeSet<String> = ["300".to_string()].into();
    let partly = fixture.inputs(&only_page);
    assert_scene(&partly.build().unwrap(), 1, "100");
    assert!(partly.build_web().unwrap().is_empty());
    assert_eq!(partly.build_native_video().unwrap().len(), 1);
}

#[test]
fn build_owned_maps_each_display_to_its_wallpaper_including_mirrors() {
    let wallpapers: BTreeMap<String, WallpaperConfig> = ["100", "200"]
        .into_iter()
        .map(|id| (id.to_string(), WallpaperConfig::new_for(id, "scene")))
        .collect();
    let config = AppConfig {
        monitors: vec![
            MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                wallpaper: Some("100".to_string()),
                ..MonitorCfg::default()
            },
            independent(3, "200"),
            MonitorCfg {
                selector: SerializedSelector::LiveDisplayId { display_id: 2 },
                enabled: true,
                mode: "mirror".to_string(),
                mirror_target: Some(SerializedSelector::Primary),
                ..MonitorCfg::default()
            },
        ],
        ..AppConfig::default()
    };
    let displays = vec![display_snapshot(1), display_snapshot(2), display_snapshot(3)];
    let paths = BridgePaths::for_home("/tmp/test-home");
    let (suspended, models, rejected) = (BTreeSet::new(), BTreeMap::new(), BTreeMap::new());
    let inputs = |held| ActivationInputs {
        app_config: &config,
        wallpapers: &wallpapers,
        library: None,
        displays: &displays,
        suspended_displays: &suspended,
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &models,
        native_video_enabled: false,
        native_video_rejected: &rejected,
        frame_rate_cap: None,
        audio_suppressed: false,
        held,
    };

    let owned = inputs(&NONE_HELD_FOR_OWNERS).build_owned().unwrap();
    let mut owners: Vec<(u32, String)> = owned
        .iter()
        .map(|(scene, owner)| (scene.display.display_id, owner.clone()))
        .collect();
    owners.sort();
    assert_eq!(
        owners,
        vec![
            (1, "100".to_string()),
            (2, "100".to_string()),
            (3, "200".to_string())
        ],
        "a mirror shows its source's wallpaper, so a crash there is that wallpaper's"
    );
    for (scene, owner) in &owned {
        assert!(
            scene.scene_path.contains(&format!("/{owner}/")),
            "the owner must be the wallpaper the scene plays: {} for {owner}",
            scene.scene_path
        );
    }
    assert_eq!(
        inputs(&NONE_HELD_FOR_OWNERS)
            .build()
            .unwrap()
            .iter()
            .map(|scene| scene.display.display_id)
            .collect::<Vec<_>>(),
        owned.iter().map(|(scene, _)| scene.display.display_id).collect::<Vec<_>>(),
        "build() is build_owned() without the owners"
    );

    // Holding the source takes its mirror with it: the mirror has no scene of
    // its own to open.
    let held: BTreeSet<String> = ["100".to_string()].into();
    let remaining: Vec<u32> = inputs(&held)
        .build_owned()
        .unwrap()
        .iter()
        .map(|(scene, _)| scene.display.display_id)
        .collect();
    assert_eq!(remaining, vec![3]);
}

static NONE_HELD_FOR_OWNERS: BTreeSet<String> = BTreeSet::new();

fn framing(pan_x: f64, pan_y: f64) -> FramingCfg {
    FramingCfg { pan_x, pan_y }
}

fn scene_framing(scenes: &[wallpaper_core::project::SceneDesc], display_id: u32) -> SceneFraming {
    scenes
        .iter()
        .find(|scene| scene.display.display_id == display_id)
        .unwrap_or_else(|| panic!("missing scene for display {display_id}"))
        .framing
}

/// One wallpaper on two displays, positioned on only one of them.
#[test]
fn a_saved_position_reaches_only_the_scene_built_for_its_display() {
    let (left, right) = (
        identified_display("left", 1),
        identified_display("right", 2),
    );
    let selector_of = |display: &DisplaySnapshotEntry| {
        SerializedSelector::from_selector(&DisplaySelector::Identity(display.identity.clone()))
    };
    let app_config = AppConfig {
        monitors: [&left, &right]
            .map(|display| MonitorCfg {
                selector: selector_of(display),
                enabled: true,
                mode: "independent".to_string(),
                wallpaper: Some("100".to_string()),
                mirror_target: None,
            })
            .into(),
        ..AppConfig::default()
    };
    let mut wallpaper = WallpaperConfig::new_for("100", "scene");
    wallpaper.monitors.push(MonitorRender {
        selector: selector_of(&left),
        framing: framing(0.2, 0.8),
        ..MonitorRender::default()
    });
    let wallpapers = BTreeMap::from([("100".to_string(), wallpaper)]);
    let displays = [left, right];
    let paths = BridgePaths::for_home("/Users/example");

    let scenes = ActivationInputs {
        app_config: &app_config,
        wallpapers: &wallpapers,
        library: None,
        displays: &displays,
        suspended_displays: &BTreeSet::new(),
        held: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
        frame_rate_cap: None,
        audio_suppressed: false,
    }
    .build()
    .unwrap();

    assert_eq!(scenes.len(), 2);
    assert_eq!(
        scene_framing(&scenes, 1),
        SceneFraming {
            pan_x: 0.2,
            pan_y: 0.8
        }
    );
    assert_eq!(
        scene_framing(&scenes, 2),
        SceneFraming::default(),
        "a display with no saved position of its own stays centred"
    );
}

/// The position is looked up the way scaling is: a display addressed as
/// Primary by one record and by identity by another is still one display.
#[test]
fn a_saved_position_follows_the_display_across_the_ways_it_is_addressed() {
    let display = identified_display("primary", 1);
    let identity_selector =
        SerializedSelector::from_selector(&DisplaySelector::Identity(display.identity.clone()));
    for (monitor_selector, render_selector) in [
        (identity_selector.clone(), SerializedSelector::Primary),
        (SerializedSelector::Primary, identity_selector),
    ] {
        let app_config = AppConfig {
            monitors: vec![MonitorCfg {
                selector: monitor_selector,
                enabled: true,
                mode: "independent".to_string(),
                wallpaper: Some("100".to_string()),
                mirror_target: None,
            }],
            ..AppConfig::default()
        };
        let mut wallpaper = WallpaperConfig::new_for("100", "scene");
        wallpaper.monitors.push(MonitorRender {
            selector: render_selector,
            framing: framing(0.0, 1.0),
            ..MonitorRender::default()
        });
        let wallpapers = BTreeMap::from([("100".to_string(), wallpaper)]);
        let paths = BridgePaths::for_home("/Users/example");

        let scenes = ActivationInputs {
            app_config: &app_config,
            wallpapers: &wallpapers,
            library: None,
            displays: std::slice::from_ref(&display),
            suspended_displays: &BTreeSet::new(),
            held: &BTreeSet::new(),
            paused: false,
            paths: &paths,
            force_shader_refresh: false,
            project_models: &BTreeMap::new(),
            native_video_enabled: false,
            native_video_rejected: &BTreeMap::new(),
            frame_rate_cap: None,
            audio_suppressed: false,
        }
        .build()
        .unwrap();

        assert_eq!(
            scene_framing(&scenes, 1),
            SceneFraming {
                pan_x: 0.0,
                pan_y: 1.0
            }
        );
    }
}

/// A mirror copies its source's scene, but a position set on the source is
/// applied to the source's handle only, so the mirror must not inherit it.
#[test]
fn a_mirror_is_centred_even_when_its_source_is_positioned() {
    let mut wallpaper = WallpaperConfig::new_for("100", "scene");
    wallpaper.monitors.push(MonitorRender {
        selector: SerializedSelector::Primary,
        framing: framing(0.1, 0.9),
        ..MonitorRender::default()
    });
    let wallpapers = BTreeMap::from([("100".to_string(), wallpaper)]);
    let app_config = AppConfig {
        monitors: vec![
            MonitorCfg {
                selector: SerializedSelector::Primary,
                enabled: true,
                wallpaper: Some("100".to_string()),
                ..MonitorCfg::default()
            },
            MonitorCfg {
                selector: SerializedSelector::LiveDisplayId { display_id: 2 },
                enabled: true,
                mode: "mirror".to_string(),
                mirror_target: Some(SerializedSelector::Primary),
                ..MonitorCfg::default()
            },
        ],
        ..AppConfig::default()
    };
    let displays = vec![display_snapshot(1), display_snapshot(2)];
    let paths = BridgePaths::for_home("/tmp/test-home");

    let scenes = ActivationInputs {
        app_config: &app_config,
        wallpapers: &wallpapers,
        library: None,
        displays: &displays,
        suspended_displays: &BTreeSet::new(),
        held: &BTreeSet::new(),
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &BTreeMap::new(),
        native_video_enabled: false,
        native_video_rejected: &BTreeMap::new(),
        frame_rate_cap: None,
        audio_suppressed: false,
    }
    .build()
    .unwrap();

    assert_eq!(scenes.len(), 2);
    assert_eq!(
        scene_framing(&scenes, 1),
        SceneFraming {
            pan_x: 0.1,
            pan_y: 0.9
        }
    );
    assert_eq!(scene_framing(&scenes, 2), SceneFraming::default());
}

/// The native player ignores a position, so moving a clip must not look like a
/// change to it: the descriptor it is handed and the key its admission is
/// judged by stay what they were, and the clip does not fall back to the engine.
#[test]
fn a_position_does_not_change_what_the_native_video_player_is_handed() {
    let mut fixture = HeldFixture::new();
    let none = BTreeSet::new();
    let before = fixture.inputs(&none).build_native_video().unwrap();
    let keys_before = fixture.inputs(&none).native_video_admission_keys();
    assert_eq!(before.len(), 1);

    let clip_on_display_3 = SerializedSelector::LiveDisplayId { display_id: 3 };
    fixture
        .wallpapers
        .get_mut("500")
        .unwrap()
        .monitors
        .push(MonitorRender {
            selector: clip_on_display_3.clone(),
            framing: framing(0.1, 0.9),
            ..MonitorRender::default()
        });
    assert_eq!(
        fixture.inputs(&none).build_native_video().unwrap(),
        before,
        "the player is handed the same clip with the same settings"
    );
    assert_eq!(
        fixture.inputs(&none).native_video_admission_keys(),
        keys_before
    );
    assert_eq!(
        fixture.inputs(&none).build().unwrap().len(),
        1,
        "and the engine is still given only the scene wallpaper"
    );

    // The same record does reach the player once it holds something the
    // player honours, so the equality above is not a record that was never found.
    fixture.wallpapers.get_mut("500").unwrap().monitors[0].scaling_mode = "fit".to_string();
    let fitted = fixture.inputs(&none).build_native_video().unwrap();
    assert_eq!(fitted[0].scaling_mode, ScalingMode::Fit);
}
