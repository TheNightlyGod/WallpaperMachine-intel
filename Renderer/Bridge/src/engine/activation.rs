//! Translate bridge state into the `SceneDesc` list consumed by engine
//! reconciliation, plus the web-wallpaper descriptors the host renders itself.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use wallpaper_core::{
    DisplayDesc, DisplaySnapshotEntry,
    media::audio::AudioVolume,
    project::{ScalingMode, SceneDesc, SceneFraming, WallpaperProjectType},
};

use crate::{
    api::{BridgeError, BridgeErrorKind, BridgeWallpaperEntry},
    config::{AppConfig, MonitorCfg, MonitorSettingsCfg, WallpaperConfig},
    display::DisplayDescExt,
    paths::BridgePaths,
    project::{ProjectModel, PropertyKind, PropertyValue},
};

/// A gain every wallpaper's own volume is multiplied by while the host wants
/// wallpapers turned down without muting them: 1 leaves the volume alone and
/// 0 silences it. Transient like the mute on top of a saved mute, and never
/// saved: the saved volume stays what the user chose.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AudioGain(f32);

impl AudioGain {
    /// Every wallpaper at the volume saved for it.
    pub const UNITY: Self = Self(1.0);

    /// # Errors
    ///
    /// Returns an invalid-input error unless `gain` is a number from 0 to 1.
    pub fn new(gain: f32) -> Result<Self, BridgeError> {
        if gain.is_finite() && (0.0..=1.0).contains(&gain) {
            Ok(Self(gain))
        } else {
            Err(BridgeError::invalid_input(format!(
                "audio gain {gain} is outside the range 0 to 1"
            )))
        }
    }

    /// `volume` as it plays under this gain. Every host takes the product
    /// here, so the volume a scene opens with, the one a live change sends
    /// and the one an unchanged check compares against are the same number.
    #[must_use]
    pub fn applied_to(self, volume: f32) -> f32 {
        volume * self.0
    }

    /// [`Self::applied_to`] for a scene's validated volume.
    #[must_use]
    pub fn applied_to_volume(self, volume: AudioVolume) -> AudioVolume {
        // Two numbers from 0 to 1 multiply to one, so the fallback is never taken.
        AudioVolume::try_from(self.applied_to(f32::from(volume))).unwrap_or(volume)
    }
}

pub struct ActivationInputs<'a> {
    pub app_config: &'a AppConfig,
    pub wallpapers: &'a BTreeMap<String, WallpaperConfig>,
    /// Installed wallpapers from the last successful library scan; `None`
    /// before one. A monitor assigned a wallpaper missing from a scanned
    /// library (deleted while its display was disconnected, or removed outside
    /// the app) gets nothing: handing the engine a project that no longer
    /// exists fails the whole reconcile, so one stale display would block
    /// applying a wallpaper to any other.
    pub library: Option<&'a [BridgeWallpaperEntry]>,
    pub displays: &'a [DisplaySnapshotEntry],
    /// Conditions that apply to every display: the user's Play/Pause choice,
    /// power policy, display sleep and session lock.
    pub paused: bool,
    /// Displays whose own presentation is suspended, by occlusion for example.
    /// Hiding one screen must not pause the wallpaper on another.
    pub suspended_displays: &'a BTreeSet<u32>,
    pub paths: &'a BridgePaths,
    pub force_shader_refresh: bool,
    /// Parsed manifests keyed by wallpaper id. Web projects are routed to
    /// [`ActivationInputs::build_web`] instead of the scene engine; ids
    /// without a model are treated as engine-rendered.
    pub project_models: &'a BTreeMap<String, ProjectModel>,
    /// Global frame-rate ceiling in force. `None` means no limit. Call sites
    /// pass `active_target_fps_cap()`, so it already includes the profile's
    /// cap while Reduced quality is selected and the Mac is on battery, and
    /// while a quality throttle holds. Web and native-video descriptors carry
    /// the capped rate because those hosts have no later `set_fps`.
    pub frame_rate_cap: Option<u32>,
    /// Transient mute composed on top of each slot's saved mute for every playback host.
    pub audio_suppressed: bool,
    /// Transient gain composed on top of each slot's saved volume. Web and
    /// native-video descriptors carry the product because those hosts have no
    /// later volume change of their own; a scene takes it in `live_scene`.
    pub audio_gain: AudioGain,
    /// Wallpapers the load journal holds back because the app died while
    /// opening them in consecutive sessions. They get no scene, web or
    /// native-video descriptor, so a display assigned one keeps what it
    /// showed. See [`crate::engine::LoadJournal`].
    pub held: &'a BTreeSet<String>,
}

/// A plain local video assigned to one display, played by the host process
/// with its own video player instead of by the scene engine.
///
/// Every project whose type is Video with a resolvable local media file reaches this. There is no
/// other player for it: a file the host cannot play is reported as a failure of that display, not
/// handed to the scene engine.
#[derive(Clone, Debug, PartialEq)]
pub struct NativeVideoWallpaperDesc {
    pub display: DisplayDesc,
    /// The display whose assignment this plays: its own, or for a mirror its source's, which it
    /// takes through `..source`. Independent assignments of one clip stay separate. The host lets
    /// one member of each group be heard, as it does for web pages.
    pub audio_source_display_id: u32,
    pub wallpaper_id: String,
    pub media_path: PathBuf,
    /// Identifies the media the host plays: the file, its length and its modification time.
    /// Identical for every member of a mirror group, so one verdict covers the group. The host keeps
    /// its verdict on a file (and a surface it opened for it) under this key, so a replaced file is
    /// judged afresh and an unchanged one is not read again. See [`native_video_admission_key`].
    ///
    /// The frame-rate cap is deliberately not part of it: the player plays a
    /// clip at the clip's own rate, so no cap decides whether it may take one.
    pub admission_key: u64,
    /// Where the picture sits on this display when it is larger or smaller than
    /// it: the saved Position of this wallpaper on this display, or centred. A
    /// mirror is centred, as the scene engine draws it, because a mirror's
    /// display settings carry no position.
    pub framing: SceneFraming,
    pub paused: bool,
    pub volume: f32,
    pub muted: bool,
    pub scaling_mode: ScalingMode,
    pub scaling_factor: f64,
    /// Wallpaper Engine's per-wallpaper options as saved; a mirror shows its source's.
    pub engine_options: crate::config::EngineOptionsCfg,
    /// The project's `schemecolor` property, the border colour in Fit-style modes.
    pub border_color: Option<[f32; 3]>,
}

/// What plays the video on one display, and whether it can.
///
/// Every plain video is played by the host's own player, so there is no backend to choose: this
/// says which display shows which wallpaper, and carries the one problem the bridge itself can see
/// (the project's media file is missing or is not a regular file). A file the player cannot play is
/// the host's to report.
#[derive(Clone, Debug, PartialEq)]
pub struct VideoBackendRouting {
    pub display: DisplayDesc,
    pub wallpaper_id: String,
    pub problem: Option<String>,
}

/// What the renderers behind the current configuration actually are.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RenderBackendSurvey {
    /// One entry per display showing a plain-video wallpaper, mirrors
    /// included: a mirror presents on its own display and is routed with its
    /// source.
    pub videos: Vec<VideoBackendRouting>,
    /// Whether anything running can honour an internal render scale: a scene
    /// rasterizes through the renderer's own targets, and a web page multiplies
    /// `window.devicePixelRatio` by the scale. A plain video decodes to its
    /// source resolution on either backend and does neither.
    pub render_scale_supported: bool,
}

/// Why a video shows nothing when the host never got as far as judging it.
///
/// Deliberately narrow: this is the one case the bridge itself can see, and
/// anything the host refused carries the host's own wording instead.
const NATIVE_VIDEO_MEDIA_UNRESOLVED: &str = "the project's video file could not be found";

/// A web wallpaper assigned to one display, rendered by the host process in a
/// web view rather than by the scene engine.
#[derive(Clone, Debug, PartialEq)]
pub struct WebWallpaperDesc {
    pub display: DisplayDesc,
    pub display_key: String,
    pub audio_source_display_id: u32,
    pub wallpaper_id: String,
    pub project_dir: PathBuf,
    pub entry_file: String,
    pub fps: u32,
    pub paused: bool,
    pub volume: f32,
    pub muted: bool,
    pub audio_response_enabled: bool,
    /// Effective user-property values (overrides over manifest defaults),
    /// excluding group and label pseudo-properties.
    pub properties: BTreeMap<String, PropertyValue>,
}

struct DirectSlot<'a> {
    display: DisplayDesc,
    wallpaper_id: &'a str,
    wallpaper: &'a WallpaperConfig,
    monitor: &'a MonitorCfg,
}

struct MirrorSlot {
    display: DisplayDesc,
    source_display_id: u32,
    settings: MonitorSettingsCfg,
}

/// One mirror group's native-video media: the file the host opens and the key that identifies it.
struct NativeVideoAdmission {
    media_path: PathBuf,
    admission_key: u64,
}

/// Offset basis and prime of the 64-bit FNV-1a hash.
const FNV1A_OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
const FNV1A_PRIME: u64 = 0x0000_0100_0000_01b3;

/// Identifies one native-video file: the path the host opens and the bytes behind that path. Those
/// are exactly the inputs the host's verdict on the file depends on. A frame-rate target is not one
/// of them: the player plays a clip at its own rate, so the same file is the same decision at every
/// target, and lowering a cap neither reopens nor refuses a running clip.
///
/// FNV-1a is written out here rather than reached for through [`std::hash`]:
/// `DefaultHasher`'s output is explicitly not guaranteed stable across Rust
/// releases. The key never outlives the session, so an unstable hash would not
/// corrupt persisted state, but a value that silently changes under a
/// toolchain upgrade is not something a reader can reason about, and this key
/// crosses the FFI boundary to the host and back. FNV-1a is a few lines, needs
/// no dependency, and yields the same key for the same inputs on every build.
///
/// Length and modification time stand in for the file's contents: hashing the
/// media itself would read hundreds of megabytes on every activation. Two
/// different clips written to the same path with the same length inside one
/// filesystem timestamp tick are indistinguishable here, and that is the
/// accepted cost — it is a re-evaluation that does not happen, never a wrong
/// frame on screen.
fn native_video_admission_key(media_path: &Path, metadata: &fs::Metadata) -> u64 {
    let modified_nanos = metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |since_epoch| since_epoch.as_nanos());
    let mut hash = fnv1a(
        FNV1A_OFFSET_BASIS,
        media_path.as_os_str().as_encoded_bytes(),
    );
    hash = fnv1a(hash, &metadata.len().to_le_bytes());
    fnv1a(hash, &modified_nanos.to_le_bytes())
}

fn fnv1a(mut hash: u64, bytes: &[u8]) -> u64 {
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV1A_PRIME);
    }
    hash
}

impl ActivationInputs<'_> {
    /// Effective paused state for one display: a global reason, or that display
    /// being suspended on its own.
    fn display_paused(&self, display_id: u32) -> bool {
        self.paused || self.suspended_displays.contains(&display_id)
    }

    /// Engine-rendered scenes for every enabled, resolved display. Web
    /// wallpapers are excluded; see [`Self::build_web`].
    ///
    /// # Errors
    ///
    /// Returns an error when an active wallpaper config cannot be converted
    /// into a scene.
    pub fn build(&self) -> Result<Vec<SceneDesc>, BridgeError> {
        Ok(self
            .build_owned()?
            .into_iter()
            .map(|(scene, _)| scene)
            .collect())
    }

    /// [`Self::build`] with the wallpaper each scene belongs to: the one
    /// assigned to its display, or for a mirror the one its source shows.
    ///
    /// # Errors
    ///
    /// Returns an error when an active wallpaper config cannot be converted
    /// into a scene.
    pub fn build_owned(&self) -> Result<Vec<(SceneDesc, String)>, BridgeError> {
        self.build_described(false)
    }

    /// The lock-screen and screen-saver export: [`Self::build`] plus a description of every plain
    /// video, which the extension plays with its own players. The descriptions only say which
    /// display shows which clip and how; nothing renders them as a scene, and a clip the extension
    /// cannot play is held and reported there, as on the desktop.
    ///
    /// # Errors
    ///
    /// Returns an error when an active wallpaper config cannot be converted
    /// into a description.
    pub fn build_lock_screen(&self) -> Result<Vec<SceneDesc>, BridgeError> {
        Ok(self
            .build_described(true)?
            .into_iter()
            .map(|(scene, _)| scene)
            .collect())
    }

    fn build_described(
        &self,
        include_videos: bool,
    ) -> Result<Vec<(SceneDesc, String)>, BridgeError> {
        let (direct, mirrors) = self.slots();
        let mut scenes: Vec<(SceneDesc, String)> = Vec::new();
        for slot in direct {
            // A wallpaper played by a host-rendered backend must not also get a
            // scene: two renderers for one display would decode and present the
            // same content twice. A plain video has no other player, so it never
            // gets one, whether or not its file can be found. Only the lock-screen
            // export describes one, for the extension's own players.
            if self.is_web(slot.wallpaper_id)
                || (self.is_native_video(slot.wallpaper_id) && !include_videos)
            {
                continue;
            }
            let owner = slot.wallpaper_id.to_string();
            scenes.push((
                super::activation_remaining::build_configured_scene(
                    self,
                    slot.monitor,
                    slot.wallpaper_id,
                    slot.wallpaper,
                    slot.display,
                )?,
                owner,
            ));
        }

        let mut mirrored: Vec<DisplayDesc> = Vec::new();
        for mirror in mirrors {
            if mirrored
                .iter()
                .any(|used| used.same_physical_display(&mirror.display))
            {
                continue;
            }
            let Some((source_scene, owner)) = scenes
                .iter()
                .find(|(scene, _)| scene.display.display_id == mirror.source_display_id)
            else {
                continue;
            };
            mirrored.push(mirror.display.clone());
            let scene = super::activation_remaining::build_mirror_scene(
                self,
                source_scene,
                mirror.display,
                &mirror.settings,
            )?;
            let owner = owner.clone();
            scenes.push((scene, owner));
        }

        Ok(scenes)
    }

    /// Host-rendered web wallpapers for every enabled, resolved display,
    /// including mirrors of a web source display.
    ///
    /// # Errors
    ///
    /// Returns an error when a web project has no entry file.
    pub fn build_web(&self) -> Result<Vec<WebWallpaperDesc>, BridgeError> {
        let (direct, mirrors) = self.slots();
        let mut web = Vec::new();
        for slot in direct {
            let Some(model) = self.web_model(slot.wallpaper_id) else {
                continue;
            };
            let entry_file = model.entry_file.clone().ok_or_else(|| {
                BridgeError::invalid_input(format!(
                    "web wallpaper {} declares no entry file",
                    slot.wallpaper_id
                ))
            })?;
            let overrides = model.override_values(&slot.wallpaper.property_overrides);
            let properties = model
                .properties
                .iter()
                .filter(|property| {
                    !matches!(property.kind, PropertyKind::Group | PropertyKind::Text)
                })
                .map(|property| (property.id.clone(), property.effective_value(&overrides)))
                .collect();
            let paused = self.display_paused(slot.display.display_id);
            let fps = self.slot_fps(&slot);
            web.push(WebWallpaperDesc {
                audio_source_display_id: slot.display.display_id,
                display_key: slot.monitor.selector.id(),
                display: slot.display,
                wallpaper_id: slot.wallpaper_id.to_string(),
                project_dir: self.paths.steam_workshop_root().join(slot.wallpaper_id),
                entry_file,
                fps,
                paused,
                volume: self.audio_gain.applied_to(slot.wallpaper.audio.volume),
                muted: slot.wallpaper.audio.muted || self.audio_suppressed,
                audio_response_enabled: slot.wallpaper.audio.response_enabled,
                properties,
            });
        }

        let mut mirrored: Vec<DisplayDesc> = Vec::new();
        for mirror in mirrors {
            if mirrored
                .iter()
                .any(|used| used.same_physical_display(&mirror.display))
            {
                continue;
            }
            let Some(source) = web
                .iter()
                .find(|desc| desc.display.display_id == mirror.source_display_id)
                .cloned()
            else {
                continue;
            };
            mirrored.push(mirror.display.clone());
            let fps = self.mirror_fps(&mirror);
            let paused = self.display_paused(mirror.display.display_id);
            web.push(WebWallpaperDesc {
                display_key: mirror.settings.selector.id(),
                display: mirror.display,
                fps,
                paused,
                volume: self.audio_gain.applied_to(mirror.settings.volume),
                muted: mirror.settings.muted || self.audio_suppressed,
                ..source
            });
        }

        Ok(web)
    }

    fn is_web(&self, wallpaper_id: &str) -> bool {
        self.web_model(wallpaper_id).is_some()
    }

    /// Whether the wallpaper is a plain video, which only the host's own player plays.
    fn is_native_video(&self, wallpaper_id: &str) -> bool {
        self.project_models
            .get(wallpaper_id)
            .is_some_and(|model| model.project_type == WallpaperProjectType::Video)
    }

    fn native_video_candidate(&self, wallpaper_id: &str) -> Option<NativeVideoAdmission> {
        let model = self.project_models.get(wallpaper_id)?;
        if model.project_type != WallpaperProjectType::Video {
            return None;
        }
        let file = model.entry_file.as_ref()?;
        if file.is_empty() {
            return None;
        }
        let media_path = self
            .paths
            .steam_workshop_root()
            .join(wallpaper_id)
            .join(file);
        // The player opens a path, so a project whose media is missing gets no
        // window that could never play.
        let metadata = fs::metadata(&media_path).ok()?;
        if !metadata.is_file() {
            return None;
        }
        Some(NativeVideoAdmission {
            admission_key: native_video_admission_key(&media_path, &metadata),
            media_path,
        })
    }

    #[must_use]
    pub fn render_backends(&self) -> RenderBackendSurvey {
        let (direct, mirrors) = self.slots();
        let mut videos: Vec<VideoBackendRouting> = Vec::new();
        let mut render_scale_supported = false;
        for slot in direct {
            let Some(model) = self.project_models.get(slot.wallpaper_id) else {
                continue;
            };
            match model.project_type {
                // A scene rasterizes through the renderer's own targets, and a
                // web page is handed the scale as a multiplier of its
                // `devicePixelRatio` (`BridgeWebWallpaper::render_scale`). A
                // plain video decodes to its source resolution on either
                // backend, so it honours neither.
                WallpaperProjectType::Scene | WallpaperProjectType::Web => {
                    render_scale_supported = true;
                    continue;
                }
                WallpaperProjectType::Video => {}
                WallpaperProjectType::Unknown => continue,
            }
            let problem = self
                .native_video_candidate(slot.wallpaper_id)
                .is_none()
                .then(|| NATIVE_VIDEO_MEDIA_UNRESOLVED.to_string());
            videos.push(VideoBackendRouting {
                display: slot.display,
                wallpaper_id: slot.wallpaper_id.to_string(),
                problem,
            });
        }

        let mut mirrored: Vec<DisplayDesc> = Vec::new();
        for mirror in mirrors {
            if mirrored
                .iter()
                .any(|used| used.same_physical_display(&mirror.display))
            {
                continue;
            }
            let Some(source) = videos
                .iter()
                .find(|routed| routed.display.display_id == mirror.source_display_id)
                .cloned()
            else {
                continue;
            };
            mirrored.push(mirror.display.clone());
            // A mirror never routes on its own: both backends give it a copy
            // of the source's decision.
            videos.push(VideoBackendRouting {
                display: mirror.display,
                ..source
            });
        }

        RenderBackendSurvey {
            videos,
            render_scale_supported,
        }
    }

    /// The target frame rate each display is configured for, keyed by display
    /// id, in exactly the terms [`Self::build`] gives its scenes.
    ///
    /// This is what a restored quality profile has to hand back: the user's
    /// own saved rate for that display, never a constant.
    #[must_use]
    pub fn target_frame_rates(&self) -> BTreeMap<u32, u32> {
        let (direct, mirrors) = self.slots();
        let mut rates: BTreeMap<u32, u32> = BTreeMap::new();
        for slot in &direct {
            rates.insert(slot.display.display_id, self.slot_fps(slot));
        }
        let mut mirrored: Vec<DisplayDesc> = Vec::new();
        for mirror in &mirrors {
            if mirrored
                .iter()
                .any(|used| used.same_physical_display(&mirror.display))
            {
                continue;
            }
            mirrored.push(mirror.display.clone());
            rates.insert(mirror.display.display_id, self.mirror_fps(mirror));
        }
        rates
    }

    /// This slot's effective target frame rate: the user's requested rate, or
    /// the display's own refresh when they have not chosen one, never above
    /// what the display can present or the global cap.
    fn slot_fps(&self, slot: &DirectSlot<'_>) -> u32 {
        let refresh = slot.display.refresh_rate_hz;
        // A missing override is "follow native", the same answer `fps_on`
        // gives a default render, without allocating that default on the
        // common unsaved path.
        let fps = crate::config::resolve_frame_rate(
            super::render_settings::select_render_setting(
                &slot.wallpaper.monitors,
                &slot.monitor.selector,
                &slot.display,
                self.displays,
            )
            .and_then(|render| render.frame_rate),
            refresh,
        );
        self.apply_frame_rate_cap(fps)
    }

    /// One mirror display's effective target frame rate, under the global cap.
    fn mirror_fps(&self, mirror: &MirrorSlot) -> u32 {
        let fps = mirror.settings.fps_on(mirror.display.refresh_rate_hz);
        self.apply_frame_rate_cap(fps)
    }

    fn apply_frame_rate_cap(&self, fps: u32) -> u32 {
        self.frame_rate_cap.map_or(fps, |cap| fps.min(cap.max(1)))
    }

    /// Plain local videos for every enabled, resolved display, including
    /// mirrors of a native-video source display.
    ///
    /// # Errors
    ///
    /// Returns an error when a monitor's audio volume is outside the valid
    /// range.
    pub fn build_native_video(&self) -> Result<Vec<NativeVideoWallpaperDesc>, BridgeError> {
        let (direct, mirrors) = self.slots();
        let mut videos = Vec::new();
        for slot in direct {
            let Some(admission) = self.native_video_candidate(slot.wallpaper_id) else {
                continue;
            };
            let render = super::render_settings::select_render_setting(
                &slot.wallpaper.monitors,
                &slot.monitor.selector,
                &slot.display,
                self.displays,
            );
            videos.push(NativeVideoWallpaperDesc {
                audio_source_display_id: slot.display.display_id,
                wallpaper_id: slot.wallpaper_id.to_string(),
                media_path: admission.media_path,
                admission_key: admission.admission_key,
                framing: render
                    .map(|render| render.framing.to_scene())
                    .unwrap_or_default(),
                paused: self.display_paused(slot.display.display_id),
                volume: self.audio_gain.applied_to(slot.wallpaper.audio.volume),
                muted: slot.wallpaper.audio.muted || self.audio_suppressed,
                scaling_mode: render
                    .map(crate::config::wallpaper::MonitorRender::parse_scaling_mode)
                    .unwrap_or_default(),
                scaling_factor: render.map_or(1.0, |render| render.scaling_factor),
                engine_options: slot.wallpaper.engine_options.clone(),
                border_color: self.scheme_color(slot.wallpaper_id, slot.wallpaper),
                display: slot.display,
            });
        }

        let mut mirrored: Vec<DisplayDesc> = Vec::new();
        for mirror in mirrors {
            if mirrored
                .iter()
                .any(|used| used.same_physical_display(&mirror.display))
            {
                continue;
            }
            let Some(source) = videos
                .iter()
                .find(|desc| desc.display.display_id == mirror.source_display_id)
                .cloned()
            else {
                continue;
            };
            mirrored.push(mirror.display.clone());
            // A mirror takes the source's `admission_key` through `..source`,
            // and that is correct rather than convenient: [`Self::build`]
            // gives a mirror a scene only by copying the source display's
            // scene, so a mirror cannot fall back to the engine on its own;
            // sharing one key is what makes a refusal move the whole group and
            // keeps this display from going dark.
            videos.push(NativeVideoWallpaperDesc {
                framing: SceneFraming::default(),
                paused: self.display_paused(mirror.display.display_id),
                volume: self.audio_gain.applied_to(mirror.settings.volume),
                muted: mirror.settings.muted || self.audio_suppressed,
                scaling_mode: mirror.settings.parse_scaling_mode(),
                scaling_factor: mirror.settings.scaling_factor,
                display: mirror.display,
                ..source
            });
        }

        Ok(videos)
    }

    /// The value of the project's `schemecolor` property for this wallpaper (its override, else
    /// the project default) when it is a colour. Wallpaper Engine packs it as a video's border
    /// colour (`sub_1400FFCB0`); absent means black.
    pub fn scheme_color(&self, wallpaper_id: &str, wallpaper: &WallpaperConfig) -> Option<[f32; 3]> {
        let model = self.project_models.get(wallpaper_id)?;
        let property = model.properties.iter().find(|property| property.id == "schemecolor")?;
        match property.effective_value(&model.override_values(&wallpaper.property_overrides)) {
            PropertyValue::ColorRgb(red, green, blue) => Some([red, green, blue]),
            _ => None,
        }
    }

    fn web_model(&self, wallpaper_id: &str) -> Option<&ProjectModel> {
        self.project_models
            .get(wallpaper_id)
            .filter(|model| model.project_type == WallpaperProjectType::Web)
    }

    /// Resolves enabled monitors to live displays: primary-first direct
    /// assignments, then mirrors whose display is not already used.
    fn slots(&self) -> (Vec<DirectSlot<'_>>, Vec<MirrorSlot>) {
        let mut direct = Vec::new();
        let mut mirrors = Vec::new();
        super::activation_remaining::visit_selected(
            self,
            |monitor, wallpaper, display| {
                direct.push(DirectSlot {
                    display: display.desc.clone(),
                    wallpaper_id: monitor.wallpaper.as_deref().expect("selected wallpaper"),
                    wallpaper,
                    monitor,
                });
            },
            |monitor, display, source_display_id, settings| {
                mirrors.push(MirrorSlot {
                    display: display.desc.clone(),
                    source_display_id,
                    settings: settings.cloned().unwrap_or_else(|| MonitorSettingsCfg {
                        selector: monitor.selector.clone(),
                        ..MonitorSettingsCfg::default()
                    }),
                });
            },
        );
        (direct, mirrors)
    }
}
