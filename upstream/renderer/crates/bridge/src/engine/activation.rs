//! Translate bridge state into the `SceneDesc` list consumed by engine
//! reconciliation, plus the web-wallpaper descriptors the host renders itself.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use wallpaper_core::{
    DisplayDesc, DisplaySelector, DisplaySnapshotEntry, EngineError, WallpaperAssignment,
    media::audio::AudioVolume,
    project::{
        ScalingMode, SceneDesc, SceneDescBuilder, SceneFraming, SceneTemplate, WallpaperProjectType,
    },
};

use crate::{
    api::{BridgeError, BridgeErrorKind, BridgeWallpaperEntry},
    config::{AppConfig, MonitorCfg, MonitorRender, MonitorSettingsCfg, WallpaperConfig},
    display::{DisplayDescExt, DisplaySelectorExt, DisplaySnapshotExt},
    paths::BridgePaths,
    project::{ProjectModel, PropertyKind, PropertyValue, scene_property_override_json},
};

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
    /// Whether plain local video wallpapers may be routed to the native
    /// player. Off by default; see [`ActivationInputs::build_native_video`].
    pub native_video_enabled: bool,
    /// Refusals the native player recorded, per wallpaper and then per
    /// admission key. See [`NativeVideoRejections`].
    pub native_video_rejected: &'a NativeVideoRejections,
    /// Global frame-rate ceiling in force. `None` means no limit. Call sites
    /// pass `active_target_fps_cap()`, so it already includes the profile's
    /// cap while Reduced quality is selected and the Mac is on battery, and
    /// while a quality throttle holds. Web and native-video descriptors carry
    /// the capped rate because those hosts have no later `set_fps`.
    pub frame_rate_cap: Option<u32>,
    /// Transient mute composed on top of each slot's saved mute for every playback host.
    pub audio_suppressed: bool,
    /// Wallpapers the load journal holds back because the app died while
    /// opening them in consecutive sessions. They get no scene, web or
    /// native-video descriptor, so a display assigned one keeps what it
    /// showed. See [`crate::engine::LoadJournal`].
    pub held: &'a BTreeSet<String>,
}

/// Refusals recorded per wallpaper id, then per admission key.
///
/// A wallpaper has one admission key *per display slot*, so the same clip on
/// two displays at different target rates is two independent decisions. One
/// record per wallpaper id cannot hold both: the second display's refusal
/// overwrote the first's, the first display's live key then no longer matched
/// the stored one so the record looked stale and was pruned, and the wallpaper
/// was offered natively again to a host that had already refused that exact
/// key. The host opened nothing and [`ActivationInputs::build`] had already
/// excluded the display as natively routed, so that display was left with no
/// backend at all. A refusal may only ever suppress the key it was decided
/// against.
pub type NativeVideoRejections = BTreeMap<String, BTreeMap<u64, NativeVideoRejection>>;

/// A refusal the host recorded for one native-video configuration.
///
/// Scoped by [`NativeVideoWallpaperDesc::admission_key`] rather than by
/// wallpaper id alone. A refusal is a statement about the configuration the
/// host evaluated — "60 fps clip, target 30" — not about the wallpaper
/// forever: raising the target rate, restoring an unsupported setting or
/// replacing the media file produces a different key, and that slot is offered
/// to the native backend again. Within one configuration the refusal still
/// holds for the rest of the session, so the two backends cannot hand a
/// wallpaper back and forth.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NativeVideoRejection {
    /// The host's own wording. Logged when the refusal is recorded and again
    /// when it expires, never parsed.
    pub reason: String,
}

/// A plain local video assigned to one display, played by the host process
/// with the platform video player instead of by the scene engine.
///
/// Only the declared subset reaches this: a project whose type is Video, with
/// a resolvable local media file, and with no option this backend cannot
/// honour. Everything else stays on the scene engine.
#[derive(Clone, Debug, PartialEq)]
pub struct NativeVideoWallpaperDesc {
    pub display: DisplayDesc,
    pub wallpaper_id: String,
    pub media_path: PathBuf,
    /// This display's own target frame rate. What the player runs at here.
    pub fps: u32,
    /// The target frame rate the host's accept-or-refuse answer must be judged
    /// against: the strictest [`Self::fps`] across this display's mirror group,
    /// which is this display's own when it mirrors and is mirrored by nothing.
    ///
    /// A mirror cannot fall back on its own — [`ActivationInputs::build`] only
    /// ever gives a mirror a scene by copying its source's — so the group is
    /// admitted or refused as a unit, and a unit is only safe at the rate its
    /// strictest member demands. Judging a 60 fps source and then handing that
    /// verdict to a 30 fps mirror would play the mirror at 60 under a 30 fps
    /// target: the silent rate change admission exists to prevent, arriving
    /// through the one path that never asked.
    pub admission_fps: u32,
    /// Identifies the exact inputs the host's admission decision rests on,
    /// [`Self::admission_fps`] among them. Identical for every member of a
    /// mirror group, so one verdict covers the group and a refusal recorded
    /// against it suppresses the group rather than one display. The host must
    /// echo it back when it refuses, so a refusal that arrives after the
    /// configuration changed can be discarded instead of killing a
    /// configuration it never judged. See [`native_video_admission_key`].
    pub admission_key: u64,
    pub paused: bool,
    pub volume: f32,
    pub muted: bool,
    pub scaling_mode: ScalingMode,
    pub scaling_factor: f64,
}

/// Which renderer is actually playing the video on one display.
///
/// `native` is what is running, not what was preferred. `fallback_reason` is
/// recorded only when the user asked for the native player and this display
/// did not get it, so `None` never means "no reason known" on a display the
/// user never pointed at the native player.
#[derive(Clone, Debug, PartialEq)]
pub struct VideoBackendRouting {
    pub display: DisplayDesc,
    pub wallpaper_id: String,
    pub native: bool,
    pub fallback_reason: Option<String>,
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

/// Why a video is on the scene engine when the native player was asked for and
/// the host never got as far as judging it.
///
/// Deliberately narrow: this is the one case the bridge itself can see, and
/// anything the host refused carries the host's own wording instead.
const NATIVE_VIDEO_MEDIA_UNRESOLVED: &str =
    "the project's video file could not be opened by the native player";

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

/// One mirror group's native-video candidacy: the media file the host would
/// open, the strictest target rate the group must be judged at, and the key
/// that identifies exactly that judgement.
struct NativeVideoAdmission {
    media_path: PathBuf,
    admission_fps: u32,
    admission_key: u64,
}

/// Offset basis and prime of the 64-bit FNV-1a hash.
const FNV1A_OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
const FNV1A_PRIME: u64 = 0x0000_0100_0000_01b3;

/// Identifies one native-video admission decision: the media the host would
/// open, the bytes behind that path, and the frame rate it has to hit. Those
/// are exactly the inputs the host's accept-or-refuse answer depends on.
///
/// `admission_fps` is the mirror group's strictest target, never one display's
/// own. Every member of a group therefore gets the same key, which is what
/// makes one host verdict cover the group instead of a verdict taken for the
/// source silently standing in for a slower mirror that was never evaluated.
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
fn native_video_admission_key(
    media_path: &Path,
    metadata: &fs::Metadata,
    admission_fps: u32,
) -> u64 {
    let modified_nanos = metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |since_epoch| since_epoch.as_nanos());
    let mut hash = fnv1a(FNV1A_OFFSET_BASIS, media_path.as_os_str().as_encoded_bytes());
    hash = fnv1a(hash, &metadata.len().to_le_bytes());
    hash = fnv1a(hash, &modified_nanos.to_le_bytes());
    fnv1a(hash, &admission_fps.to_le_bytes())
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
        let (direct, mirrors) = self.slots();
        let group_targets = self.mirror_group_targets(&mirrors);
        let mut scenes: Vec<(SceneDesc, String)> = Vec::new();
        for slot in direct {
            // A wallpaper routed to a host-rendered backend must not also get a
            // scene: two renderers for one display would decode and present the
            // same content twice.
            let admission_fps = self.slot_admission_fps(&slot, &group_targets);
            if self.is_web(slot.wallpaper_id)
                || self
                    .native_video_admission(&slot, admission_fps)
                    .is_some()
            {
                continue;
            }
            let owner = slot.wallpaper_id.to_string();
            scenes.push((
                self.scene_for_monitor(
                    slot.display,
                    slot.wallpaper_id,
                    slot.wallpaper,
                    slot.monitor,
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
                .cloned()
            else {
                continue;
            };
            mirrored.push(mirror.display.clone());
            let audio_volume = AudioVolume::try_from(mirror.settings.volume).map_err(|error| {
                BridgeError::Error {
                    kind: BridgeErrorKind::Engine,
                    message: EngineError::InvalidInput(error.to_string()).to_string(),
                }
            })?;
            let mut scene = source_scene;
            scene.display = mirror.display;
            // A mirror presents on its own display, so it takes that display's
            // suspension rather than the source display's.
            scene.paused = self.display_paused(scene.display.display_id);
            scene.scaling_mode = mirror.settings.parse_scaling_mode();
            scene.scaling_factor = mirror.settings.scaling_factor;
            // A mirror copies its source's scene but has its own display
            // settings, and those carry no position. A live position change on
            // the source never reaches the mirror's handle, so inheriting the
            // source's would make what the mirror shows depend on when the
            // last reconcile ran.
            scene.framing = SceneFraming::default();
            scene.fps = mirror.settings.fps_on(scene.display.refresh_rate_hz);
            scene.audio_volume = audio_volume;
            scene.audio_muted = mirror.settings.muted;
            scene.validate().map_err(|error| BridgeError::Error {
                kind: BridgeErrorKind::Engine,
                message: error.to_string(),
            })?;
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
                volume: slot.wallpaper.audio.volume,
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
                volume: mirror.settings.volume,
                muted: mirror.settings.muted || self.audio_suppressed,
                ..source
            });
        }

        Ok(web)
    }

    fn is_web(&self, wallpaper_id: &str) -> bool {
        self.web_model(wallpaper_id).is_some()
    }

    /// Whether this slot is routed to the native player right now.
    ///
    /// Requires the opt-in, a Video project, a resolvable media file, and no
    /// refusal recorded against this slot's *current* admission key. Any of
    /// those failing leaves it on the scene engine, which is the backend that
    /// supports everything.
    ///
    /// `admission_fps` is the mirror group's strictest target, from
    /// [`Self::slot_admission_fps`]. Two independent displays showing the same
    /// wallpaper at different targets have different keys and are looked up
    /// separately, so a refusal on one neither drags the other off the native
    /// player nor erases it; a mirror group shares one key and moves together,
    /// because a mirror has no scene of its own to fall back to.
    fn native_video_admission(
        &self,
        slot: &DirectSlot<'_>,
        admission_fps: u32,
    ) -> Option<NativeVideoAdmission> {
        let candidate = self.native_video_candidate(slot.wallpaper_id, admission_fps)?;
        // Only a refusal recorded against this slot's own live key applies. Any
        // other record describes a configuration that is not this one.
        self.native_video_rejected
            .get(slot.wallpaper_id)
            .is_none_or(|by_key| !by_key.contains_key(&candidate.admission_key))
            .then_some(candidate)
    }

    /// The candidate ignoring any recorded refusal.
    ///
    /// Refusals are matched by key, so the key of a refused configuration has
    /// to stay computable while that refusal is in force — otherwise a repeat
    /// refusal would look stale and a settled fallback would start flapping.
    fn native_video_candidate(
        &self,
        wallpaper_id: &str,
        admission_fps: u32,
    ) -> Option<NativeVideoAdmission> {
        if !self.native_video_enabled {
            return None;
        }
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
        // The player opens a path, so a project whose media is missing has to
        // stay on the engine rather than produce a window that can never play.
        let metadata = fs::metadata(&media_path).ok()?;
        if !metadata.is_file() {
            return None;
        }
        Some(NativeVideoAdmission {
            admission_key: native_video_admission_key(&media_path, &metadata, admission_fps),
            media_path,
            admission_fps,
        })
    }

    /// Every admission key the live configuration currently produces, per
    /// wallpaper id, ignoring recorded refusals.
    ///
    /// The caller uses this to separate a refusal that describes the live
    /// configuration from one that arrived after the user changed it, and to
    /// drop records whose configuration is gone.
    pub fn native_video_admission_keys(&self) -> BTreeMap<String, BTreeSet<u64>> {
        let (direct, mirrors) = self.slots();
        let group_targets = self.mirror_group_targets(&mirrors);
        let mut keys: BTreeMap<String, BTreeSet<u64>> = BTreeMap::new();
        for slot in direct {
            let admission_fps = self.slot_admission_fps(&slot, &group_targets);
            let Some(candidate) = self.native_video_candidate(slot.wallpaper_id, admission_fps)
            else {
                continue;
            };
            keys.entry(slot.wallpaper_id.to_string())
                .or_default()
                .insert(candidate.admission_key);
        }
        keys
    }

    /// What is actually rendering right now: which backend plays each video,
    /// and whether anything on screen can honour an internal render scale.
    ///
    /// Reported from the same routing decision [`Self::build`] and
    /// [`Self::build_native_video`] make, so a display cannot be described as
    /// native here while the scene engine is the one holding it.
    #[must_use]
    pub fn render_backends(&self) -> RenderBackendSurvey {
        let (direct, mirrors) = self.slots();
        let group_targets = self.mirror_group_targets(&mirrors);
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
            let admission_fps = self.slot_admission_fps(&slot, &group_targets);
            let candidate = self.native_video_candidate(slot.wallpaper_id, admission_fps);
            let refusal = candidate.as_ref().and_then(|candidate| {
                self.native_video_rejected
                    .get(slot.wallpaper_id)?
                    .get(&candidate.admission_key)
            });
            let native = candidate.is_some() && refusal.is_none();
            // A reason is a statement about a choice the user made. With the
            // scene engine selected there is no fallback to explain.
            let fallback_reason = (self.native_video_enabled && !native).then(|| {
                refusal.map_or_else(
                    || NATIVE_VIDEO_MEDIA_UNRESOLVED.to_string(),
                    |record| record.reason.clone(),
                )
            });
            videos.push(VideoBackendRouting {
                display: slot.display,
                wallpaper_id: slot.wallpaper_id.to_string(),
                native,
                fallback_reason,
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
            RenderOverrideResolver {
                wallpaper: slot.wallpaper,
                monitor: slot.monitor,
                display: &slot.display,
                displays: self.displays,
            }
            .resolve()
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
        self.frame_rate_cap
            .map_or(fps, |cap| fps.min(cap.max(1)))
    }

    /// The strictest mirror target per source display id.
    ///
    /// Mirrors are deduplicated by physical display exactly as the build loops
    /// deduplicate them, so the rate a group is judged at is the rate a group
    /// member will actually run at.
    fn mirror_group_targets(&self, mirrors: &[MirrorSlot]) -> BTreeMap<u32, u32> {
        let mut strictest: BTreeMap<u32, u32> = BTreeMap::new();
        let mut counted: Vec<DisplayDesc> = Vec::new();
        for mirror in mirrors {
            if counted
                .iter()
                .any(|used| used.same_physical_display(&mirror.display))
            {
                continue;
            }
            counted.push(mirror.display.clone());
            let fps = self.mirror_fps(mirror);
            strictest
                .entry(mirror.source_display_id)
                .and_modify(|current| *current = (*current).min(fps))
                .or_insert(fps);
        }
        strictest
    }

    /// The target frame rate this slot's admission must be judged against: the
    /// strictest across the mirror group it heads, or its own when it heads
    /// none.
    ///
    /// A group is admitted or refused as a unit because a mirror has no scene
    /// of its own to fall back to, and a unit is only safe at the rate its
    /// strictest member demands.
    fn slot_admission_fps(
        &self,
        slot: &DirectSlot<'_>,
        group_targets: &BTreeMap<u32, u32>,
    ) -> u32 {
        let own = self.slot_fps(slot);
        group_targets
            .get(&slot.display.display_id)
            .map_or(own, |mirrored| own.min(*mirrored))
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
        let group_targets = self.mirror_group_targets(&mirrors);
        let mut videos = Vec::new();
        for slot in direct {
            let admission_fps = self.slot_admission_fps(&slot, &group_targets);
            let Some(admission) = self.native_video_admission(&slot, admission_fps) else {
                continue;
            };
            let render = RenderOverrideResolver {
                wallpaper: slot.wallpaper,
                monitor: slot.monitor,
                display: &slot.display,
                displays: self.displays,
            }
            .resolve();
            videos.push(NativeVideoWallpaperDesc {
                wallpaper_id: slot.wallpaper_id.to_string(),
                media_path: admission.media_path,
                // This display's own rate, which may be looser than the rate the
                // group was judged at.
                fps: self.slot_fps(&slot),
                admission_fps: admission.admission_fps,
                admission_key: admission.admission_key,
                paused: self.display_paused(slot.display.display_id),
                volume: slot.wallpaper.audio.volume,
                muted: slot.wallpaper.audio.muted || self.audio_suppressed,
                scaling_mode: render
                    .map(crate::config::wallpaper::MonitorRender::parse_scaling_mode)
                    .unwrap_or_default(),
                scaling_factor: render.map_or(1.0, |render| render.scaling_factor),
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
            let fps = self.mirror_fps(&mirror);
            // A mirror takes the source's `admission_fps` and `admission_key`
            // through `..source`, and that is correct rather than convenient:
            // the source was judged at the group minimum, which already
            // accounts for this mirror's own target. [`Self::build`] gives a
            // mirror a scene only by copying the source display's scene, so a
            // mirror cannot fall back to the engine on its own; sharing one key
            // is what makes a refusal move the whole group and keeps this
            // display from going dark. Its own `fps` still reports the rate it
            // runs at here.
            videos.push(NativeVideoWallpaperDesc {
                fps,
                paused: self.display_paused(mirror.display.display_id),
                volume: mirror.settings.volume,
                muted: mirror.settings.muted || self.audio_suppressed,
                scaling_mode: mirror.settings.parse_scaling_mode(),
                scaling_factor: mirror.settings.scaling_factor,
                display: mirror.display,
                ..source
            });
        }

        Ok(videos)
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
        let mut used_displays: Vec<DisplayDesc> = Vec::new();
        let mut monitors = self.app_config.monitors.iter().collect::<Vec<_>>();
        monitors.sort_by_key(|monitor| {
            i32::from(monitor.selector != crate::config::SerializedSelector::Primary)
        });

        for monitor in monitors {
            if !monitor.enabled {
                continue;
            }

            let Some(wallpaper_id) = monitor.wallpaper.as_deref() else {
                continue;
            };

            let Some(wallpaper) = self.wallpapers.get(wallpaper_id) else {
                continue;
            };

            if self
                .library
                .is_some_and(|library| !library.iter().any(|entry| entry.id == wallpaper_id))
            {
                // Debug, not warn: snapshots rebuild this plan on every refresh.
                log::debug!(
                    "wallpaper {wallpaper_id} is assigned to a display but is not in the \
                     library; leaving that display empty"
                );
                continue;
            }

            if self.held.contains(wallpaper_id) {
                // Debug, not warn: snapshots rebuild this plan on every refresh.
                // The bridge said why once, when it learned the wallpaper is held.
                log::debug!(
                    "wallpaper {wallpaper_id} is held back by the load journal; \
                     leaving its display as it is"
                );
                continue;
            }

            if monitor.mode == "mirror" {
                continue;
            }

            let Some(display) = monitor.resolve_display(self.displays) else {
                continue;
            };
            if used_displays
                .iter()
                .any(|used| used.same_physical_display(&display))
            {
                continue;
            }

            used_displays.push(display.clone());
            direct.push(DirectSlot {
                display,
                wallpaper_id,
                wallpaper,
                monitor,
            });
        }

        let mut mirrors = Vec::new();
        for monitor in self
            .app_config
            .monitors
            .iter()
            .filter(|monitor| monitor.enabled && monitor.mode.eq_ignore_ascii_case("mirror"))
        {
            let Some(display) = monitor.resolve_display(self.displays) else {
                continue;
            };
            if used_displays
                .iter()
                .any(|used| used.same_physical_display(&display))
            {
                continue;
            }
            let Some(target) = monitor.mirror_target.as_ref() else {
                continue;
            };
            let Some(source_display_id) = target
                .to_selector()
                .resolve_display(self.displays)
                .map(|entry| entry.desc.display_id)
            else {
                continue;
            };
            let settings = self
                .app_config
                .monitor_settings
                .iter()
                .find(|settings| settings.selector == monitor.selector)
                .cloned()
                .unwrap_or_else(|| MonitorSettingsCfg {
                    selector: monitor.selector.clone(),
                    ..MonitorSettingsCfg::default()
                });
            mirrors.push(MirrorSlot {
                display,
                source_display_id,
                settings,
            });
        }

        (direct, mirrors)
    }

    fn scene_for_monitor(
        &self,
        display: DisplayDesc,
        wallpaper_id: &str,
        wallpaper: &WallpaperConfig,
        monitor: &MonitorCfg,
    ) -> Result<SceneDesc, BridgeError> {
        let display_paused = self.display_paused(display.display_id);
        SceneDescBuilder::build_from_wallpaper_config(SceneBuildContext {
            display,
            workshop_id: wallpaper_id,
            wallpaper,
            model: self.project_models.get(wallpaper_id),
            monitor,
            displays: self.displays,
            paused: display_paused,
            paths: self.paths,
            force_shader_refresh: self.force_shader_refresh,
        })
    }
}

pub trait WallpaperAssignmentExt {
    fn build_mirror_assignments(
        app_config: &AppConfig,
        displays: &[DisplaySnapshotEntry],
    ) -> Vec<(DisplaySelector, WallpaperAssignment)>;
}

impl WallpaperAssignmentExt for WallpaperAssignment {
    fn build_mirror_assignments(
        app_config: &AppConfig,
        displays: &[DisplaySnapshotEntry],
    ) -> Vec<(DisplaySelector, WallpaperAssignment)> {
        let mut assignments = Vec::new();

        for monitor in &app_config.monitors {
            if !monitor.enabled || monitor.mode != "mirror" {
                continue;
            }
            if monitor
                .selector
                .to_selector()
                .resolve_display(displays)
                .is_none()
            {
                continue;
            }
            let Some(target) = monitor.mirror_target.as_ref() else {
                continue;
            };
            assignments.push((
                monitor.selector.to_selector(),
                WallpaperAssignment::Mirror(target.to_selector()),
            ));
        }

        assignments
    }
}

trait MonitorCfgActivationExt {
    fn resolve_display(&self, displays: &[DisplaySnapshotEntry]) -> Option<DisplayDesc>;
}

impl MonitorCfgActivationExt for MonitorCfg {
    fn resolve_display(&self, displays: &[DisplaySnapshotEntry]) -> Option<DisplayDesc> {
        self.selector
            .to_selector()
            .resolve_display(displays)
            .map(|entry| entry.desc.clone())
    }
}

pub trait SceneDescBuilderExt {
    fn build_from_wallpaper_config(
        context: SceneBuildContext<'_>,
    ) -> Result<SceneDesc, BridgeError>
    where
        Self: Sized;
}

impl SceneDescBuilderExt for SceneDescBuilder {
    fn build_from_wallpaper_config(
        context: SceneBuildContext<'_>,
    ) -> Result<SceneDesc, BridgeError> {
        let project_json = context.paths.project_json(context.workshop_id);
        let assets_path = context.paths.assets_root();
        let audio_volume =
            AudioVolume::try_from(context.wallpaper.audio.volume).map_err(|error| {
                BridgeError::Error {
                    kind: BridgeErrorKind::Engine,
                    message: EngineError::InvalidInput(error.to_string()).to_string(),
                }
            })?;
        let render_override = RenderOverrideResolver {
            wallpaper: context.wallpaper,
            monitor: context.monitor,
            display: &context.display,
            displays: context.displays,
        }
        .resolve();
        let fps = crate::config::resolve_frame_rate(
            render_override.and_then(|render| render.frame_rate),
            context.display.refresh_rate_hz,
        );
        let scaling_mode = render_override
            .map(crate::config::wallpaper::MonitorRender::parse_scaling_mode)
            .unwrap_or_default();
        let scaling_factor = render_override.map_or(1.0, |render| render.scaling_factor);
        let framing = render_override
            .map(|render| render.framing.to_scene())
            .unwrap_or_default();
        let property_override_json = if context.wallpaper.r#type.eq_ignore_ascii_case("scene") {
            // Also the builder of the document a live preview shows, so what
            // is previewed is what this loads.
            scene_property_override_json(context.model, &context.wallpaper.property_overrides)
        } else {
            None
        };
        let mut builder = SceneTemplate::builder(project_json.to_string_lossy())
            .assets_path(assets_path.to_string_lossy())
            .fps(fps)
            .paused(context.paused)
            .scaling_mode(scaling_mode)
            .scaling_factor(scaling_factor)
            .framing(framing)
            .audio_response_enabled(context.wallpaper.audio.response_enabled)
            // Reading what the user is listening to is consent, not a
            // capability: the scene is told exactly what the inspector shows,
            // and the lock-screen path forces the flag off after apply.
            .media_integration_enabled(context.wallpaper.media_integration_enabled)
            .audio_volume(audio_volume.into())
            .audio_muted(context.wallpaper.audio.muted)
            .shader_cache_path(context.paths.shader_cache_root().to_string_lossy())
            .force_shader_refresh(context.force_shader_refresh);

        if let Some(json) = property_override_json {
            builder = builder.property_override_json(json);
        }

        builder
            .build()
            .map(|template| template.for_display(context.display))
            .map_err(|error| BridgeError::Error {
                kind: BridgeErrorKind::Engine,
                message: error.to_string(),
            })
    }
}

pub struct SceneBuildContext<'a> {
    display: DisplayDesc,
    workshop_id: &'a str,
    wallpaper: &'a WallpaperConfig,
    /// Parsed manifest, for the defaults this host supplies rather than reads
    /// from the project file the scene engine parses for itself.
    model: Option<&'a ProjectModel>,
    monitor: &'a MonitorCfg,
    displays: &'a [DisplaySnapshotEntry],
    paused: bool,
    paths: &'a BridgePaths,
    force_shader_refresh: bool,
}

struct RenderOverrideResolver<'a> {
    wallpaper: &'a WallpaperConfig,
    monitor: &'a MonitorCfg,
    display: &'a DisplayDesc,
    displays: &'a [DisplaySnapshotEntry],
}

impl<'a> RenderOverrideResolver<'a> {
    fn resolve(&self) -> Option<&'a MonitorRender> {
        self.wallpaper
            .monitors
            .iter()
            .find(|render| render.selector == self.monitor.selector)
            .or_else(|| {
                self.wallpaper
                    .monitors
                    .iter()
                    .find(|render| self.matches(render))
            })
    }

    fn matches(&self, render: &MonitorRender) -> bool {
        let Some(display_snapshot) = self.display_snapshot() else {
            return false;
        };

        if render.selector == crate::config::SerializedSelector::Primary {
            return self
                .displays
                .first()
                .is_some_and(|primary| display_snapshot.matches_primary(primary));
        }

        let render_selector = render.selector.to_selector();
        render_selector.matches_display(display_snapshot)
    }

    fn display_snapshot(&self) -> Option<&'a DisplaySnapshotEntry> {
        self.displays
            .iter()
            .find(|display| display.desc.same_physical_display(self.display))
    }
}
