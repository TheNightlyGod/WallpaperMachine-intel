use std::collections::{BTreeMap, BTreeSet};

use wallpaper_core::{
    DisplaySelector, DisplaySnapshotEntry,
    project::{ScalingMode, SceneFraming},
};

use super::{
    fixture_observations::assert_owner,
    fixture_values::{anonymous, identified},
};

use crate::{
    api::{BridgeWallpaperEntry, BridgeWallpaperKind},
    config::{
        AppConfig, FramingCfg, MonitorCfg, MonitorRender, SerializedSelector,
        WallpaperConfig,
    },
    engine::ActivationInputs,
    paths::BridgePaths,
};

#[test]
fn activation_plan_leaves_display_empty_when_assigned_wallpaper_left_the_library() {
    // A wallpaper deleted while its display was disconnected keeps its
    // assignment. Planning a scene for it would fail the whole reconcile and
    // block applying anything to any other display.
    let display_a = identified("a", 1, 60);
    let display_b = identified("b", 3, 60);
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
        frame_rate_cap: None,
        audio_suppressed: false,
    }
    .build()
    .unwrap();

    assert_eq!(scenes.len(), 1);
    assert_owner(&scenes, 1, "100");
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

/// The routing rules themselves, with no actor and no host query in the way.
///
/// Every plain video is played by the host's own player, so a Video project never gets a scene
/// and always gets a descriptor when its file is there; the scene engine has no say in it. Only
/// the lock-screen export asks for the video as a scene as well.
#[test]
fn a_plain_video_is_never_a_scene_and_is_always_a_native_descriptor_when_its_file_exists() {
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
    let displays = vec![anonymous(1, 2.0, 60, true)];
    let suspended = BTreeSet::new();
    let plan = || ActivationInputs {
        app_config: &config,
        wallpapers: &wallpapers,
        library: None,
        displays: &displays,
        suspended_displays: &suspended,
        paused: false,
        paths: &paths,
        force_shader_refresh: false,
        project_models: &project_models,
        frame_rate_cap: None,
        audio_suppressed: false,
        held: &NONE_HELD,
    };
    static NONE_HELD: BTreeSet<String> = BTreeSet::new();

    assert_eq!(plan().build_native_video().unwrap().len(), 1);
    assert!(plan().build().unwrap().is_empty(), "the engine is not given a video it has no part in");
    assert_eq!(plan().render_backends().videos[0].problem, None);
    assert_eq!(
        plan().build_lock_screen().unwrap().len(),
        1,
        "the lock-screen export describes the video for the extension's own players"
    );
    // The key is the file's identity: a replaced file is a different key, a frame-rate cap is not.
    let key = plan().build_native_video().unwrap()[0].admission_key;
    let capped = ActivationInputs { frame_rate_cap: Some(15), ..plan() };
    assert_eq!(capped.build_native_video().unwrap()[0].admission_key, key);
    std::fs::write(project_dir.join("clip.mp4"), b"a longer clip than before").unwrap();
    assert_ne!(plan().build_native_video().unwrap()[0].admission_key, key);

    // A video whose file is gone gets neither descriptor nor scene, and the report says why.
    std::fs::remove_file(project_dir.join("clip.mp4")).unwrap();
    assert!(plan().build_native_video().unwrap().is_empty());
    assert!(plan().build().unwrap().is_empty(), "no scene stands in for a file that cannot be found");
    assert_eq!(
        plan().build_lock_screen().unwrap().len(),
        1,
        "the lock screen still names the video, so its extension holds the missing clip with a reason"
    );
    assert_eq!(
        plan().render_backends().videos[0].problem.as_deref(),
        Some("the project's video file could not be found")
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
            displays: vec![anonymous(1, 2.0, 60, true), anonymous(2, 2.0, 60, true), anonymous(3, 2.0, 60, true)],
            suspended: BTreeSet::new(),
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
    assert_owner(&partly.build().unwrap(), 1, "100");
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
    let displays = vec![anonymous(1, 2.0, 60, true), anonymous(2, 2.0, 60, true), anonymous(3, 2.0, 60, true)];
    let paths = BridgePaths::for_home("/tmp/test-home");
    let (suspended, models) = (BTreeSet::new(), BTreeMap::new());
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
        identified("left", 1, 60),
        identified("right", 2, 60),
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
    let display = identified("primary", 1, 60);
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
    let displays = vec![anonymous(1, 2.0, 60, true), anonymous(2, 2.0, 60, true)];
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

/// The native player places its picture by the saved position, so the
/// descriptor it is handed carries it. A position says nothing about the file,
/// so the key the host judges the file by stays what it was.
#[test]
fn a_position_reaches_the_native_video_player_without_changing_its_key() {
    let mut fixture = HeldFixture::new();
    let none = BTreeSet::new();
    let before = fixture.inputs(&none).build_native_video().unwrap();
    assert_eq!(before.len(), 1);
    assert_eq!(before[0].framing, SceneFraming::default(), "centred until moved");

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
    let moved = fixture.inputs(&none).build_native_video().unwrap();
    assert_eq!(moved.len(), 1);
    assert_eq!(
        moved[0].framing,
        framing(0.1, 0.9).to_scene(),
        "the player is handed where the user put the picture"
    );
    let mut recentred = moved[0].clone();
    recentred.framing = SceneFraming::default();
    assert_eq!(recentred, before[0], "and nothing else about the descriptor moved");
    assert_eq!(moved[0].admission_key, before[0].admission_key, "a position says nothing about the file");
    assert_eq!(
        fixture.inputs(&none).build().unwrap().len(),
        1,
        "and the engine is still given only the scene wallpaper"
    );

    fixture.wallpapers.get_mut("500").unwrap().monitors[0].scaling_mode = "fit".to_string();
    let fitted = fixture.inputs(&none).build_native_video().unwrap();
    assert_eq!(fitted[0].scaling_mode, ScalingMode::Fit);
}
