// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fmt::Display,
    path::{Path, PathBuf},
};

use serde_json::Value;

use crate::{
    DisplayDesc, EngineError,
    display::state::{DisplayKey, DisplayStateModel},
    media::audio::AudioVolume,
    project::{SceneSourceResolution, validate_relative_normal_path},
    render::{ShaderCacheDecision, ShaderCacheInputs},
};

#[derive(Clone, Debug, PartialEq)]
pub struct SceneFile {
    objects: Vec<Value>,
    scene: SceneIr,
}

/// Keys of a scene object that may name an asset file, in the order they are read.
const ASSET_KEYS: [&str; 4] = ["image", "particle", "sound", "light"];

type AssetLoader<'a> = dyn FnMut(&str) -> Result<Option<String>, crate::EngineError> + 'a;

impl SceneFile {
    /// # Errors
    ///
    /// Returns `InvalidInput` for invalid JSON, a root that is not an object or an
    /// unsafe asset reference.
    pub fn parse<T: AsRef<str>>(json: T) -> Result<Self, crate::EngineError> {
        Self::parse_with_assets(json, |_| Ok(None))
    }

    /// # Errors
    ///
    /// Returns `InvalidInput` for invalid JSON, a root that is not an object, an
    /// unsafe asset reference or an asset that is not JSON; a loader error is returned as is.
    pub fn parse_with_assets<T, F>(json: T, mut loader: F) -> Result<Self, crate::EngineError>
    where
        T: AsRef<str>,
        F: FnMut(&str) -> Result<Option<String>, crate::EngineError>,
    {
        Self::parse_checked(json.as_ref(), &mut loader)
    }

    fn parse_checked(json: &str, loader: &mut AssetLoader<'_>) -> Result<Self, EngineError> {
        let root: Value = serde_json::from_str(json)
            .map_err(|error| invalid_scene(format!("failed to parse scene file: {error}")))?;
        if !root.is_object() {
            return Err(invalid_scene("scene file root must be an object"));
        }

        let objects = match root.get("objects") {
            Some(Value::Array(items)) => items.clone(),
            _ => Vec::new(),
        };

        for object in &objects {
            for key in ASSET_KEYS {
                let Some(reference) = object.get(key).and_then(Value::as_str) else {
                    continue;
                };
                validate_relative_normal_path(Path::new(reference), "scene asset path")?;
                if let Some(text) = loader(reference)? {
                    serde_json::from_str::<Value>(&text).map_err(|error| {
                        invalid_scene(format!("failed to parse scene asset `{reference}`: {error}"))
                    })?;
                }
            }
        }

        Ok(Self {
            objects,
            scene: SceneIr::from(&root),
        })
    }

    /// # Errors
    ///
    /// Returns `InvalidInput` when the project is not a scene, an entry or asset leaves
    /// its folder, a file cannot be read or the scene does not parse.
    pub fn load_project<P, A>(project_path: P, assets_path: A) -> Result<Self, crate::EngineError>
    where
        P: AsRef<Path>,
        A: AsRef<Path>,
    {
        let project_path = project_path.as_ref();
        let assets_root = assets_path.as_ref();

        let (scene_text, project_root) =
            if project_path.file_name().is_some_and(|name| name == "project.json") {
                let SceneSourceResolution::Scene { scene_source, .. } =
                    SceneSourceResolution::load(project_path)?
                else {
                    return Err(invalid_scene("project is not a scene wallpaper"));
                };
                let entry = Path::new(&scene_source.pkg_entry);
                validate_relative_normal_path(entry, "scene file")?;
                let folder = folder_or_here(&scene_source.pkg_dir);
                let file = read_contained(&folder, entry, "scene file").map_err(|error| match error {
                    ContainedError::Escapes(message) => invalid_scene(message),
                    ContainedError::Io(error) => {
                        invalid_scene(format!("failed to read scene file: {error}"))
                    }
                })?;
                (file, folder)
            } else {
                let text = std::fs::read_to_string(project_path)
                    .map_err(|error| invalid_scene(format!("failed to read scene file: {error}")))?;
                let folder = folder_or_here(project_path.parent().unwrap_or_else(|| Path::new("")));
                (text, folder)
            };

        let mut loader = |reference: &str| -> Result<Option<String>, EngineError> {
            validate_relative_normal_path(Path::new(reference), "scene asset path")?;
            for root in [project_root.as_path(), assets_root] {
                if root.as_os_str().is_empty() {
                    continue;
                }
                if !root.join(reference).exists() {
                    continue;
                }
                return match read_contained(root, Path::new(reference), "scene asset") {
                    Ok(text) => Ok(Some(text)),
                    Err(ContainedError::Escapes(message)) => Err(invalid_scene(message)),
                    Err(ContainedError::Io(error)) => Err(invalid_scene(format!(
                        "failed to read scene asset `{reference}`: {error}"
                    ))),
                };
            }
            Ok(None)
        };
        Self::parse_checked(&scene_text, &mut loader)
    }

    #[must_use]
    pub fn objects(&self) -> &[Value] {
        &self.objects
    }

    #[must_use]
    pub fn scene(&self) -> &SceneIr {
        &self.scene
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SceneIr {
    render_targets: BTreeMap<String, SceneRenderTargetIr>,
}

impl SceneIr {
    #[must_use]
    pub fn render_targets(&self) -> &BTreeMap<String, SceneRenderTargetIr> {
        &self.render_targets
    }
}

impl From<&Value> for SceneIr {
    fn from(value: &Value) -> Self {
        let projection = value
            .get("general")
            .and_then(|general| general.get("orthogonalprojection"));
        let side = |name: &str, default: u32| {
            projection
                .and_then(|projection| projection.get(name))
                .and_then(Value::as_u64)
                .and_then(|number| u32::try_from(number).ok())
                .unwrap_or(default)
        };
        let target = SceneRenderTargetIr {
            width: side("width", DEFAULT_CANVAS_WIDTH),
            height: side("height", DEFAULT_CANVAS_HEIGHT),
        };
        Self {
            render_targets: BTreeMap::from([(DEFAULT_RENDER_TARGET.to_owned(), target)]),
        }
    }
}

const DEFAULT_RENDER_TARGET: &str = "_rt_default";
const DEFAULT_CANVAS_WIDTH: u32 = 1920;
const DEFAULT_CANVAS_HEIGHT: u32 = 1080;

fn invalid_scene(message: impl Into<String>) -> EngineError {
    EngineError::InvalidInput(message.into())
}

/// An empty folder path means the current folder.
fn folder_or_here(folder: &Path) -> PathBuf {
    if folder.as_os_str().is_empty() {
        PathBuf::from(".")
    } else {
        folder.to_path_buf()
    }
}

enum ContainedError {
    Escapes(String),
    Io(std::io::Error),
}

/// Reads `relative` below `root` after resolving links, refusing a file whose real
/// location is outside the real `root`.
fn read_contained(root: &Path, relative: &Path, label: &str) -> Result<String, ContainedError> {
    let real_root = root.canonicalize().map_err(ContainedError::Io)?;
    let real_file = root.join(relative).canonicalize().map_err(ContainedError::Io)?;
    if !real_file.starts_with(&real_root) {
        return Err(ContainedError::Escapes(format!(
            "{label} must stay under its root"
        )));
    }
    std::fs::read_to_string(real_file).map_err(ContainedError::Io)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SceneHandle(u64);

impl SceneHandle {
    #[must_use]
    pub fn new(raw: u64) -> Self {
        Self(raw)
    }

    #[must_use]
    pub fn raw(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub enum ScalingMode {
    None,
    Stretch,
    Fit,
    #[default]
    Fill,
    /// `Fit`'s picture, with the room around it filled by a blurred, darkened
    /// copy of the same picture.
    FitBlurred,
}

impl Display for ScalingMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::None => "none",
            Self::Stretch => "stretch",
            Self::Fit => "fit",
            Self::Fill => "fill",
            Self::FitBlurred => "fit_blurred",
        })
    }
}

/// Where the presented wallpaper sits inside the room its display leaves around
/// it.
///
/// Each axis is a fraction of that room: `0.0` puts the wallpaper's leading
/// edge on the display's (left, and top), `1.0` its trailing edge (right, and
/// bottom) and `0.5` centres it. The room is the display minus the wallpaper,
/// so one fraction places a wallpaper that leaves bars (Fit, Original size, a
/// scale factor below 1) and one that overflows the display (Fill, a scale
/// factor above 1) alike, and an axis with no room is unmoved by any value.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SceneFraming {
    /// Horizontal fraction, `0.0` (left) to `1.0` (right).
    pub pan_x: f64,
    /// Vertical fraction, `0.0` (top) to `1.0` (bottom).
    pub pan_y: f64,
}

impl SceneFraming {
    /// The wallpaper in the middle of its display on both axes.
    pub const CENTERED: Self = Self {
        pan_x: 0.5,
        pan_y: 0.5,
    };

    /// Whether both axes are finite fractions between 0 and 1.
    #[must_use]
    pub fn is_valid(self) -> bool {
        (0.0..=1.0).contains(&self.pan_x) && (0.0..=1.0).contains(&self.pan_y)
    }

    /// Rejects a framing the renderer must never see.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError::InvalidInput`] if an axis is not a finite fraction
    /// between 0 and 1.
    pub fn validate(self) -> Result<(), EngineError> {
        if self.is_valid() {
            Ok(())
        } else {
            Err(EngineError::InvalidInput(
                "framing must be fractions between 0 and 1".to_string(),
            ))
        }
    }
}

impl Default for SceneFraming {
    fn default() -> Self {
        Self::CENTERED
    }
}


/// Shadow and volumetric quality. Numbers are Wallpaper Engine's
/// (wallpaper64.exe `sub_14010DF40`): "disabled" 0 … "ultra" 4.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(i32)]
pub enum QualityLevel {
    Off = 0,
    Low = 1,
    #[default]
    Medium = 2,
    High = 3,
    Ultra = 4,
}

/// Post-processing level, Wallpaper Engine's words disabled / enabled / ultra /
/// displayhdr. Only Ultra and Display HDR draw HDR bloom; Enabled is LDR bloom.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(i32)]
pub enum PostProcessing {
    Disabled = 0,
    #[default]
    Enabled = 2,
    Ultra = 4,
    DisplayHdr = 5,
}

/// The scene quality a scene is parsed with. The defaults are Wallpaper
/// Engine's first-run "medium" preset (its UI's `getQualityPreset("medium")`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SceneQuality {
    /// MSAA samples: 0, 2, 4 or 8.
    pub msaa: u8,
    pub shadows: QualityLevel,
    pub volumetrics: QualityLevel,
    pub reflection: bool,
    pub post_processing: PostProcessing,
}

impl Default for SceneQuality {
    fn default() -> Self {
        Self {
            msaa: 0,
            shadows: QualityLevel::Medium,
            volumetrics: QualityLevel::Medium,
            reflection: true,
            post_processing: PostProcessing::Enabled,
        }
    }
}

impl SceneQuality {
    /// # Errors
    ///
    /// Returns `InvalidInput` when `msaa` is not 0, 2, 4 or 8.
    pub fn validate(self) -> Result<(), EngineError> {
        if matches!(self.msaa, 0 | 2 | 4 | 8) {
            Ok(())
        } else {
            Err(invalid("msaa must be 0, 2, 4 or 8"))
        }
    }

    /// The quality a renderer read-back (`owe_scene_quality`) describes; `None`
    /// when a value is outside the known sets.
    #[must_use]
    pub fn from_raw(msaa: i32, shadows: i32, volumetrics: i32, reflection: bool, post: i32) -> Option<Self> {
        let level = |value: i32| match value {
            0 => Some(QualityLevel::Off),
            1 => Some(QualityLevel::Low),
            2 => Some(QualityLevel::Medium),
            3 => Some(QualityLevel::High),
            4 => Some(QualityLevel::Ultra),
            _ => None,
        };
        let post_processing = match post {
            0 => PostProcessing::Disabled,
            2 => PostProcessing::Enabled,
            4 => PostProcessing::Ultra,
            5 => PostProcessing::DisplayHdr,
            _ => return None,
        };
        let quality = Self {
            msaa: u8::try_from(msaa).ok()?,
            shadows: level(shadows)?,
            volumetrics: level(volumetrics)?,
            reflection,
            post_processing,
        };
        quality.validate().ok().map(|()| quality)
    }

    /// A short stable text for cache keys and logs.
    #[must_use]
    pub fn key(self) -> String {
        format!(
            "msaa={} shadows={} volumetrics={} reflection={} post={}",
            self.msaa,
            self.shadows as i32,
            self.volumetrics as i32,
            u8::from(self.reflection),
            self.post_processing as i32
        )
    }
}

/// Wallpaper Engine's per-wallpaper options (plan decision I2; wallpaper64.exe
/// `sub_140104B60` builds them, `sub_140181F30` / `sub_140115280` apply them to
/// a scene). Values are as stored: sliders 0..=100 with 50 unchanged,
/// `lut_strength` 0..=100, `playback_rate` 10..=200 percent. The default changes
/// nothing.
#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, PartialEq)]
pub struct SceneUserOptions {
    pub color_enabled: bool,
    pub brightness: f32,
    pub contrast: f32,
    pub saturation: f32,
    pub hue: f32,
    /// A file stem under `materials/lut`; empty for no image filter.
    pub lut: String,
    pub lut_strength: f32,
    pub flip_horizontal: bool,
    pub mouse_parallax: bool,
    /// Percent; a scene runs its clock at `max(rate / 100, 0.1)`.
    pub playback_rate: f32,
}

impl Default for SceneUserOptions {
    fn default() -> Self {
        Self {
            color_enabled: false,
            brightness: 50.0,
            contrast: 50.0,
            saturation: 50.0,
            hue: 50.0,
            lut: String::new(),
            lut_strength: 100.0,
            flip_horizontal: false,
            mouse_parallax: true,
            playback_rate: 100.0,
        }
    }
}

impl SceneUserOptions {
    /// # Errors
    ///
    /// Returns `InvalidInput` when a slider is outside 0..=100 or not finite, the
    /// playback rate is outside 10..=200, or `lut` is not a plain file stem
    /// (1..=64 of `[A-Za-z0-9._-]`, not `.` or `..`).
    pub fn validate(&self) -> Result<(), EngineError> {
        let sliders = [self.brightness, self.contrast, self.saturation, self.hue, self.lut_strength];
        if sliders.iter().any(|value| !value.is_finite() || !(0.0..=100.0).contains(value)) {
            return Err(invalid("user option sliders must be between 0 and 100"));
        }
        if !self.playback_rate.is_finite() || !(10.0..=200.0).contains(&self.playback_rate) {
            return Err(invalid("the playback rate must be between 10 and 200 percent"));
        }
        if !self.lut.is_empty() && !is_plain_lut_name(&self.lut) {
            return Err(invalid("the image filter must be a plain file name"));
        }
        Ok(())
    }

    /// Whether the options leave the picture, the pointer and the clock as they are.
    #[must_use]
    pub fn is_identity(&self) -> bool {
        let colour_unchanged = !self.color_enabled
            || [self.brightness, self.contrast, self.saturation, self.hue]
                .iter()
                .all(|value| (*value - 50.0).abs() <= f32::EPSILON);
        let filter_unchanged = self.lut.is_empty() || self.lut_strength <= 0.0;
        colour_unchanged
            && filter_unchanged
            && !self.flip_horizontal
            && self.mouse_parallax
            && (self.playback_rate - 100.0).abs() <= f32::EPSILON
    }
}

fn is_plain_lut_name(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name != "."
        && name != ".."
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, PartialEq)]
pub struct SceneDesc {
    pub display: DisplayDesc,
    pub scene_path: String,
    pub assets_path: String,
    pub fps: u32,
    pub scaling_mode: ScalingMode,
    pub scaling_factor: f64,
    /// Initial position of the wallpaper inside the room its display leaves.
    pub framing: SceneFraming,
    pub paused: bool,
    pub audio_response_enabled: bool,
    /// Whether this desktop scene should receive now-playing events.
    pub media_integration_enabled: bool,
    pub audio_volume: AudioVolume,
    pub audio_muted: bool,
    pub property_override_json: Option<String>,
    pub shader_cache_path: Option<String>,
    pub force_shader_refresh: bool,
    /// The scene quality settings; a change reloads the scene.
    pub quality: SceneQuality,
    /// Folder of the scripts' `localStorage` (plan decision I3); `None` keeps it in memory.
    pub scene_storage_dir: Option<String>,
    /// Wallpaper Engine's per-wallpaper options; a change reloads the scene, and an
    /// edit that is not saved yet is shown through `OweScene::preview_user_options`.
    pub user_options: SceneUserOptions,
    /// Set when `with_audio_volume` was given a value the volume type refuses;
    /// `validate` reports it.
    rejected_audio_volume: bool,
}

const AUDIO_VOLUME_MESSAGE: &str = "audio_volume must be finite and within [0.0, 1.0]";

fn invalid(message: &str) -> EngineError {
    EngineError::InvalidInput(message.to_owned())
}

/// The checks every entry point shares once the display is out of the picture, in
/// the order they are reported.
fn check_wallpaper_fields(
    scene_path: &str,
    fps: u32,
    scaling_factor: f64,
    framing: SceneFraming,
) -> Result<(), EngineError> {
    if scene_path.is_empty() {
        return Err(invalid("scene_path must not be empty"));
    }
    if fps == 0 {
        return Err(invalid("fps must be greater than zero"));
    }
    if !scaling_factor.is_finite() || scaling_factor <= 0.0 {
        return Err(invalid("scaling factor must be finite and greater than zero"));
    }
    framing.validate()
}

fn full_volume() -> AudioVolume {
    AudioVolume::try_from(1.0).expect("1.0 is a valid volume")
}

impl SceneDesc {
    #[must_use]
    pub fn builder(display: DisplayDesc, scene_path: impl Into<String>) -> SceneDescBuilder {
        SceneDescBuilder {
            display,
            scene_path: scene_path.into(),
            assets_path: String::new(),
            fps: 60,
            scaling_mode: ScalingMode::default(),
            scaling_factor: 1.0,
            framing: SceneFraming::default(),
            paused: false,
            audio_response_enabled: false,
            media_integration_enabled: false,
            audio_volume: 1.0,
            audio_muted: false,
            property_override_json: None,
            shader_cache_path: None,
            force_shader_refresh: false,
            quality: SceneQuality::default(),
            scene_storage_dir: None,
            user_options: SceneUserOptions::default(),
        }
    }

    #[must_use]
    pub fn new(
        display: DisplayDesc,
        scene_path: impl Into<String>,
        assets_path: impl Into<String>,
        fps: u32,
        paused: bool,
    ) -> Self {
        Self {
            display,
            scene_path: scene_path.into(),
            assets_path: assets_path.into(),
            fps,
            scaling_mode: ScalingMode::default(),
            scaling_factor: 1.0,
            framing: SceneFraming::default(),
            paused,
            audio_response_enabled: false,
            media_integration_enabled: false,
            audio_volume: full_volume(),
            audio_muted: false,
            property_override_json: None,
            shader_cache_path: None,
            force_shader_refresh: false,
            quality: SceneQuality::default(),
            scene_storage_dir: None,
            user_options: SceneUserOptions::default(),
            rejected_audio_volume: false,
        }
    }

    /// # Errors
    ///
    /// Returns `InvalidInput` naming the first field the renderer could not take.
    pub fn validate(&self) -> Result<(), EngineError> {
        if self.display.display_id == 0 {
            return Err(invalid("display_id must be non-zero"));
        }
        if self.display.width == 0 || self.display.height == 0 {
            return Err(invalid("display dimensions must be non-zero"));
        }
        check_wallpaper_fields(
            &self.scene_path,
            self.fps,
            self.scaling_factor,
            self.framing,
        )?;
        self.quality.validate()?;
        self.user_options.validate()?;
        if self.rejected_audio_volume {
            return Err(invalid(AUDIO_VOLUME_MESSAGE));
        }
        Ok(())
    }

    #[must_use]
    pub fn with_audio_response_enabled(mut self, enabled: bool) -> Self {
        self.audio_response_enabled = enabled;
        self
    }

    /// Sets whether this desktop scene should receive now-playing events.
    #[must_use]
    pub fn with_media_integration_enabled(mut self, enabled: bool) -> Self {
        self.media_integration_enabled = enabled;
        self
    }

    #[must_use]
    pub fn with_scaling_mode(mut self, scaling_mode: ScalingMode) -> Self {
        self.scaling_mode = scaling_mode;
        self
    }

    #[must_use]
    pub fn with_scaling_factor(mut self, scaling_factor: f64) -> Self {
        self.scaling_factor = scaling_factor;
        self
    }

    /// Sets the initial position inside the room the display leaves.
    #[must_use]
    pub fn with_framing(mut self, framing: SceneFraming) -> Self {
        self.framing = framing;
        self
    }

    #[must_use]
    pub fn with_audio_volume(mut self, audio_volume: f32) -> Self {
        match AudioVolume::try_from(audio_volume) {
            Ok(volume) => {
                self.audio_volume = volume;
                self.rejected_audio_volume = false;
            }
            Err(_) => self.rejected_audio_volume = true,
        }
        self
    }

    #[must_use]
    pub fn with_audio_muted(mut self, audio_muted: bool) -> Self {
        self.audio_muted = audio_muted;
        self
    }

    #[must_use]
    pub fn with_property_override_json(mut self, property_override_json: impl Into<String>) -> Self {
        self.property_override_json = Some(property_override_json.into());
        self
    }

    #[must_use]
    pub fn with_shader_cache_path(mut self, shader_cache_path: impl Into<String>) -> Self {
        self.shader_cache_path = Some(shader_cache_path.into());
        self
    }

    #[must_use]
    pub fn with_quality(mut self, quality: SceneQuality) -> Self {
        self.quality = quality;
        self
    }

    #[must_use]
    pub fn with_scene_storage_dir(mut self, dir: impl Into<String>) -> Self {
        self.scene_storage_dir = Some(dir.into());
        self
    }

    #[must_use]
    pub fn with_user_options(mut self, user_options: SceneUserOptions) -> Self {
        self.user_options = user_options;
        self
    }

    #[must_use]
    pub fn with_force_shader_refresh(mut self, force_shader_refresh: bool) -> Self {
        self.force_shader_refresh = force_shader_refresh;
        self
    }

    /// The prepared shader cache directory of this scene, or `None` when no cache root
    /// is set or the project is not a scene.
    ///
    /// # Errors
    ///
    /// Returns an error when the scene path is unsafe or the cache cannot be prepared.
    pub fn shader_cache_path(&self) -> Result<Option<String>, EngineError> {
        let Some(cache_root) = self.shader_cache_path.as_deref().filter(|root| !root.is_empty())
        else {
            return Ok(None);
        };
        let source = SceneSourceResolution::load(&self.scene_path)?;
        let SceneSourceResolution::Scene { scene_source, .. } = &source else {
            return Ok(None);
        };

        let inputs = ShaderCacheInputs::builder(&scene_source.scene_id, cache_root)
            .project_json_path(&self.scene_path)
            .scene_pkg_path(&scene_source.pkg_path)
            .unpacked_source(
                scene_source.pkg_dir.join(&scene_source.pkg_entry),
                &scene_source.pkg_dir,
            )
            .property_override_json(self.property_override_json.clone())
            .force_refresh(self.force_shader_refresh)
            .scene_quality_key(self.quality.key())
            .build()?;
        let decision = ShaderCacheDecision::prepare(&inputs)?;
        Ok(Some(decision.scene_cache_path().to_string_lossy().into_owned()))
    }

    /// Whether `other` asks for the same picture as this scene: everything but
    /// the display it sits on and whether it is currently paused.
    #[must_use]
    pub fn same_wallpaper(&self, other: &SceneDesc) -> bool {
        let factors_agree = (self.scaling_factor - other.scaling_factor).abs() <= f64::EPSILON;
        let places = (&self.scene_path, &self.assets_path, &self.shader_cache_path);
        let other_places = (&other.scene_path, &other.assets_path, &other.shader_cache_path);
        let timing = (self.fps, self.scaling_mode, self.framing);
        let other_timing = (other.fps, other.scaling_mode, other.framing);
        let switches = [
            self.audio_response_enabled,
            self.media_integration_enabled,
            self.audio_muted,
            self.force_shader_refresh,
        ];
        let other_switches = [
            other.audio_response_enabled,
            other.media_integration_enabled,
            other.audio_muted,
            other.force_shader_refresh,
        ];
        factors_agree
            && places == other_places
            && timing == other_timing
            && switches == other_switches
            && self.audio_volume == other.audio_volume
            && self.property_override_json == other.property_override_json
            && self.quality == other.quality
            && self.scene_storage_dir == other.scene_storage_dir
            && self.user_options == other.user_options
    }

    /// Called once the renderer has rebuilt its shader cache, so a later
    /// reconcile does not force another rebuild.
    pub fn mark_shader_refresh_complete(&mut self) {
        self.force_shader_refresh = false;
    }
}

#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, PartialEq)]
pub struct SceneTemplate {
    pub scene_path: String,
    pub assets_path: String,
    pub fps: u32,
    pub scaling_mode: ScalingMode,
    pub scaling_factor: f64,
    /// Initial position of the wallpaper inside the room its display leaves.
    pub framing: SceneFraming,
    pub paused: bool,
    pub audio_response_enabled: bool,
    /// Whether this desktop scene should receive now-playing events.
    pub media_integration_enabled: bool,
    pub audio_volume: AudioVolume,
    pub audio_muted: bool,
    pub property_override_json: Option<String>,
    pub shader_cache_path: Option<String>,
    pub force_shader_refresh: bool,
    /// The scene quality settings; a change reloads the scene.
    pub quality: SceneQuality,
    /// Folder of the scripts' `localStorage` (plan decision I3); `None` keeps it in memory.
    pub scene_storage_dir: Option<String>,
    /// Wallpaper Engine's per-wallpaper options; a change reloads the scene.
    pub user_options: SceneUserOptions,
}

impl SceneTemplate {
    #[must_use]
    pub fn builder(scene_path: impl Into<String>) -> SceneTemplateBuilder {
        SceneTemplateBuilder {
            scene_path: scene_path.into(),
            assets_path: String::new(),
            fps: 60,
            scaling_mode: ScalingMode::default(),
            scaling_factor: 1.0,
            framing: SceneFraming::default(),
            paused: false,
            audio_response_enabled: false,
            media_integration_enabled: false,
            audio_volume: 1.0,
            audio_muted: false,
            property_override_json: None,
            shader_cache_path: None,
            force_shader_refresh: false,
            quality: SceneQuality::default(),
            scene_storage_dir: None,
            user_options: SceneUserOptions::default(),
        }
    }

    /// The reusable part of `scene`: everything except the display it runs on.
    #[must_use]
    pub fn from_scene_desc(scene: &SceneDesc) -> Self {
        let SceneDesc {
            scene_path,
            assets_path,
            fps,
            scaling_mode,
            scaling_factor,
            framing,
            paused,
            audio_response_enabled,
            media_integration_enabled,
            audio_volume,
            audio_muted,
            property_override_json,
            shader_cache_path,
            force_shader_refresh,
            quality,
            scene_storage_dir,
            user_options,
            ..
        } = scene;
        Self {
            scene_path: scene_path.clone(),
            assets_path: assets_path.clone(),
            fps: *fps,
            scaling_mode: *scaling_mode,
            scaling_factor: *scaling_factor,
            framing: *framing,
            paused: *paused,
            audio_response_enabled: *audio_response_enabled,
            media_integration_enabled: *media_integration_enabled,
            audio_volume: *audio_volume,
            audio_muted: *audio_muted,
            property_override_json: property_override_json.clone(),
            shader_cache_path: shader_cache_path.clone(),
            force_shader_refresh: *force_shader_refresh,
            quality: *quality,
            scene_storage_dir: scene_storage_dir.clone(),
            user_options: user_options.clone(),
        }
    }

    /// Places the template on `display`. Nothing is validated here.
    #[must_use]
    pub fn for_display(&self, display: DisplayDesc) -> SceneDesc {
        let mut scene = SceneDesc::new(
            display,
            self.scene_path.clone(),
            self.assets_path.clone(),
            self.fps,
            self.paused,
        );
        scene.scaling_mode = self.scaling_mode;
        scene.scaling_factor = self.scaling_factor;
        scene.framing = self.framing;
        scene.audio_response_enabled = self.audio_response_enabled;
        scene.media_integration_enabled = self.media_integration_enabled;
        scene.audio_volume = self.audio_volume;
        scene.audio_muted = self.audio_muted;
        scene.property_override_json.clone_from(&self.property_override_json);
        scene.shader_cache_path.clone_from(&self.shader_cache_path);
        scene.force_shader_refresh = self.force_shader_refresh;
        scene.quality = self.quality;
        scene.scene_storage_dir.clone_from(&self.scene_storage_dir);
        scene.user_options.clone_from(&self.user_options);
        scene
    }

    /// # Errors
    ///
    /// Returns `InvalidInput` naming the first field the renderer could not take.
    pub fn validate(&self) -> Result<(), EngineError> {
        check_wallpaper_fields(
            &self.scene_path,
            self.fps,
            self.scaling_factor,
            self.framing,
        )?;
        self.quality.validate()?;
        self.user_options.validate()
    }
}

#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, PartialEq)]
pub struct SceneTemplateBuilder {
    scene_path: String,
    assets_path: String,
    fps: u32,
    scaling_mode: ScalingMode,
    scaling_factor: f64,
    framing: SceneFraming,
    paused: bool,
    audio_response_enabled: bool,
    media_integration_enabled: bool,
    audio_volume: f32,
    audio_muted: bool,
    property_override_json: Option<String>,
    shader_cache_path: Option<String>,
    force_shader_refresh: bool,
    quality: SceneQuality,
    scene_storage_dir: Option<String>,
    user_options: SceneUserOptions,
}

impl SceneTemplateBuilder {
    #[must_use]
    pub fn assets_path(mut self, assets_path: impl Into<String>) -> Self {
        self.assets_path = assets_path.into();
        self
    }

    #[must_use]
    pub fn fps(mut self, fps: u32) -> Self {
        self.fps = fps;
        self
    }

    #[must_use]
    pub fn scaling_mode(mut self, scaling_mode: ScalingMode) -> Self {
        self.scaling_mode = scaling_mode;
        self
    }

    #[must_use]
    pub fn scaling_factor(mut self, scaling_factor: f64) -> Self {
        self.scaling_factor = scaling_factor;
        self
    }

    /// Sets the initial position inside the room the display leaves.
    #[must_use]
    pub fn framing(mut self, framing: SceneFraming) -> Self {
        self.framing = framing;
        self
    }

    #[must_use]
    pub fn paused(mut self, paused: bool) -> Self {
        self.paused = paused;
        self
    }

    #[must_use]
    pub fn audio_response_enabled(mut self, enabled: bool) -> Self {
        self.audio_response_enabled = enabled;
        self
    }

    /// Sets whether this desktop scene should receive now-playing events.
    #[must_use]
    pub fn media_integration_enabled(mut self, enabled: bool) -> Self {
        self.media_integration_enabled = enabled;
        self
    }

    #[must_use]
    pub fn audio_volume(mut self, audio_volume: f32) -> Self {
        self.audio_volume = audio_volume;
        self
    }

    #[must_use]
    pub fn audio_muted(mut self, audio_muted: bool) -> Self {
        self.audio_muted = audio_muted;
        self
    }

    #[must_use]
    pub fn property_override_json(mut self, json: impl Into<String>) -> Self {
        self.property_override_json = Some(json.into());
        self
    }

    #[must_use]
    pub fn shader_cache_path(mut self, path: impl Into<String>) -> Self {
        self.shader_cache_path = Some(path.into());
        self
    }

    #[must_use]
    pub fn force_shader_refresh(mut self, refresh: bool) -> Self {
        self.force_shader_refresh = refresh;
        self
    }

    #[must_use]
    pub fn quality(mut self, quality: SceneQuality) -> Self {
        self.quality = quality;
        self
    }

    #[must_use]
    pub fn scene_storage_dir(mut self, dir: impl Into<String>) -> Self {
        self.scene_storage_dir = Some(dir.into());
        self
    }

    #[must_use]
    pub fn user_options(mut self, user_options: SceneUserOptions) -> Self {
        self.user_options = user_options;
        self
    }

    /// # Errors
    ///
    /// Returns `InvalidInput` for the first problem found; a bad audio volume is
    /// reported only when every other field is valid.
    pub fn build(self) -> Result<SceneTemplate, EngineError> {
        let Self {
            scene_path,
            assets_path,
            fps,
            scaling_mode,
            scaling_factor,
            framing,
            paused,
            audio_response_enabled,
            media_integration_enabled,
            audio_volume: requested_volume,
            audio_muted,
            property_override_json,
            shader_cache_path,
            force_shader_refresh,
            quality,
            scene_storage_dir,
            user_options,
        } = self;
        let (audio_volume, volume_rejected) = match AudioVolume::try_from(requested_volume) {
            Ok(volume) => (volume, false),
            Err(_) => (full_volume(), true),
        };
        let template = SceneTemplate {
            scene_path,
            assets_path,
            fps,
            scaling_mode,
            scaling_factor,
            framing,
            paused,
            audio_response_enabled,
            media_integration_enabled,
            audio_volume,
            audio_muted,
            property_override_json,
            shader_cache_path,
            force_shader_refresh,
            quality,
            scene_storage_dir,
            user_options,
        };
        template.validate()?;
        if volume_rejected {
            return Err(invalid(AUDIO_VOLUME_MESSAGE));
        }
        Ok(template)
    }
}

pub trait SceneDescSliceExt {
    /// # Errors
    ///
    /// Returns an error if multiple scenes target the same display.
    fn assert_unique(&self) -> Result<(), EngineError>;

    /// # Errors
    ///
    /// Returns an error if a scene cannot be mapped to a display key or handle.
    fn reconcile_results(
        &self,
        display_state: &DisplayStateModel,
        handles_by_display: &HashMap<DisplayKey, SceneHandle>,
    ) -> Result<Vec<SceneResult>, EngineError>;
}

impl SceneDescSliceExt for [SceneDesc] {
    fn assert_unique(&self) -> Result<(), EngineError> {
        let mut seen = HashSet::with_capacity(self.len());
        for scene in self {
            if !seen.insert(scene.display.display_id) {
                return Err(EngineError::InvalidInput(format!(
                    "desired scene list contains duplicate display_id {}",
                    scene.display.display_id
                )));
            }
        }
        Ok(())
    }

    fn reconcile_results(
        &self,
        display_state: &DisplayStateModel,
        handles_by_display: &HashMap<DisplayKey, SceneHandle>,
    ) -> Result<Vec<SceneResult>, EngineError> {
        self.iter()
            .map(|scene| {
                let key = display_state.reconcile_key(scene)?;
                let handle = handles_by_display.get(&key).copied().ok_or_else(|| {
                    EngineError::Platform(format!(
                        "missing scene handle for requested display {}",
                        scene.display.display_id
                    ))
                })?;
                Ok(SceneResult::new(scene.display.display_id, handle, 0))
            })
            .collect()
    }
}

#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, PartialEq)]
pub struct SceneDescBuilder {
    display: DisplayDesc,
    scene_path: String,
    assets_path: String,
    fps: u32,
    scaling_mode: ScalingMode,
    scaling_factor: f64,
    framing: SceneFraming,
    paused: bool,
    audio_response_enabled: bool,
    media_integration_enabled: bool,
    audio_volume: f32,
    audio_muted: bool,
    property_override_json: Option<String>,
    shader_cache_path: Option<String>,
    force_shader_refresh: bool,
    quality: SceneQuality,
    scene_storage_dir: Option<String>,
    user_options: SceneUserOptions,
}

impl SceneDescBuilder {
    #[must_use]
    pub fn assets_path(mut self, assets_path: impl Into<String>) -> Self {
        self.assets_path = assets_path.into();
        self
    }

    #[must_use]
    pub fn fps(mut self, fps: u32) -> Self {
        self.fps = fps;
        self
    }

    #[must_use]
    pub fn scaling_mode(mut self, scaling_mode: ScalingMode) -> Self {
        self.scaling_mode = scaling_mode;
        self
    }

    #[must_use]
    pub fn scaling_factor(mut self, scaling_factor: f64) -> Self {
        self.scaling_factor = scaling_factor;
        self
    }

    /// Sets the initial position inside the room the display leaves.
    #[must_use]
    pub fn framing(mut self, framing: SceneFraming) -> Self {
        self.framing = framing;
        self
    }

    #[must_use]
    pub fn paused(mut self, paused: bool) -> Self {
        self.paused = paused;
        self
    }

    #[must_use]
    pub fn audio_response_enabled(mut self, enabled: bool) -> Self {
        self.audio_response_enabled = enabled;
        self
    }

    /// Sets whether this desktop scene should receive now-playing events.
    #[must_use]
    pub fn media_integration_enabled(mut self, enabled: bool) -> Self {
        self.media_integration_enabled = enabled;
        self
    }

    #[must_use]
    pub fn audio_volume(mut self, audio_volume: f32) -> Self {
        self.audio_volume = audio_volume;
        self
    }

    #[must_use]
    pub fn audio_muted(mut self, audio_muted: bool) -> Self {
        self.audio_muted = audio_muted;
        self
    }

    #[must_use]
    pub fn property_override_json(mut self, json: impl Into<String>) -> Self {
        self.property_override_json = Some(json.into());
        self
    }

    #[must_use]
    pub fn shader_cache_path(mut self, path: impl Into<String>) -> Self {
        self.shader_cache_path = Some(path.into());
        self
    }

    #[must_use]
    pub fn force_shader_refresh(mut self, refresh: bool) -> Self {
        self.force_shader_refresh = refresh;
        self
    }

    #[must_use]
    pub fn quality(mut self, quality: SceneQuality) -> Self {
        self.quality = quality;
        self
    }

    #[must_use]
    pub fn scene_storage_dir(mut self, dir: impl Into<String>) -> Self {
        self.scene_storage_dir = Some(dir.into());
        self
    }

    #[must_use]
    pub fn user_options(mut self, user_options: SceneUserOptions) -> Self {
        self.user_options = user_options;
        self
    }

    /// # Errors
    ///
    /// Returns `InvalidInput` for the first problem found in the wallpaper
    /// fields; a bad audio volume is reported last. The display is not
    /// checked here (see `SceneDesc::validate`).
    pub fn build(self) -> Result<SceneDesc, EngineError> {
        let Self {
            display,
            scene_path,
            assets_path,
            fps,
            scaling_mode,
            scaling_factor,
            framing,
            paused,
            audio_response_enabled,
            media_integration_enabled,
            audio_volume: requested_volume,
            audio_muted,
            property_override_json,
            shader_cache_path,
            force_shader_refresh,
            quality,
            scene_storage_dir,
            user_options,
        } = self;
        let (audio_volume, volume_rejected) = match AudioVolume::try_from(requested_volume) {
            Ok(volume) => (volume, false),
            Err(_) => (full_volume(), true),
        };
        check_wallpaper_fields(&scene_path, fps, scaling_factor, framing)?;
        quality.validate()?;
        user_options.validate()?;
        if volume_rejected {
            return Err(invalid(AUDIO_VOLUME_MESSAGE));
        }
        Ok(SceneDesc {
            display,
            scene_path,
            assets_path,
            fps,
            scaling_mode,
            scaling_factor,
            framing,
            paused,
            audio_response_enabled,
            media_integration_enabled,
            audio_volume,
            audio_muted,
            property_override_json,
            shader_cache_path,
            force_shader_refresh,
            quality,
            scene_storage_dir,
            user_options,
            rejected_audio_volume: false,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SceneResult {
    pub display_id: u32,
    pub handle: SceneHandle,
    pub status: i32,
}

impl SceneResult {
    #[must_use]
    pub fn new(display_id: u32, handle: SceneHandle, status: i32) -> Self {
        Self {
            display_id,
            handle,
            status,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{ScalingMode, SceneDesc, SceneFraming, SceneHandle, SceneResult, SceneTemplate};
    use crate::{DisplayDesc, EngineError};

    #[test]
    fn scene_descriptor_can_enable_audio_response() {
        let display = DisplayDesc::new(42, -1920, 0, 1920, 1080, 2.0);
        let scene = SceneDesc::new(display, "/scene/project.json", "/scene/assets", 60, false)
            .with_audio_response_enabled(true);

        assert!(scene.audio_response_enabled);
    }

    #[test]
    fn scene_descriptor_can_enable_media_integration() {
        let display = DisplayDesc::new(42, -1920, 0, 1920, 1080, 2.0);
        let scene = SceneDesc::new(display, "/scene/project.json", "/scene/assets", 60, false)
            .with_media_integration_enabled(true);

        assert!(scene.media_integration_enabled);
    }

    #[test]
    fn scene_result_keeps_handle_and_status() {
        let result = SceneResult::new(7, SceneHandle::new(99), 0);

        assert_eq!(result.display_id, 7);
        assert_eq!(result.handle.raw(), 99);
        assert_eq!(result.status, 0);
    }

    #[test]
    fn scaling_mode_defaults_to_fill() {
        assert_eq!(ScalingMode::default(), ScalingMode::Fill);
    }

    const FRAMING_MESSAGE: &str = "framing must be fractions between 0 and 1";

    fn off_the_map_framings() -> Vec<SceneFraming> {
        let mut framings = Vec::new();
        for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -0.1, 1.1] {
            framings.push(SceneFraming {
                pan_x: bad,
                pan_y: 0.5,
            });
            framings.push(SceneFraming {
                pan_x: 0.5,
                pan_y: bad,
            });
        }
        framings
    }

    fn assert_framing_rejected(error: EngineError) {
        match error {
            EngineError::InvalidInput(message) => assert_eq!(message, FRAMING_MESSAGE),
            other => panic!("expected invalid input, got {other:?}"),
        }
    }

    #[test]
    fn descriptors_and_templates_default_to_centred_framing() {
        let display = DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0);
        let centred = SceneFraming {
            pan_x: 0.5,
            pan_y: 0.5,
        };

        assert_eq!(SceneFraming::default(), centred);
        assert_eq!(
            SceneDesc::new(display.clone(), "/p.json", "/assets", 60, false).framing,
            centred
        );
        assert_eq!(
            SceneDesc::builder(display, "/p.json")
                .build()
                .expect("scene should build")
                .framing,
            centred
        );
        assert_eq!(
            SceneTemplate::builder("/p.json")
                .build()
                .expect("template should build")
                .framing,
            centred
        );
    }

    #[test]
    fn framing_accepts_both_ends_of_each_axis() {
        for (pan_x, pan_y) in [(0.0, 0.0), (1.0, 1.0), (0.0, 1.0), (1.0, 0.0), (0.25, 0.75)] {
            let framing = SceneFraming { pan_x, pan_y };

            assert!(framing.is_valid(), "{pan_x}/{pan_y} should be a position");
            SceneTemplate::builder("/p.json")
                .framing(framing)
                .build()
                .expect("template should accept it");
            SceneDesc::builder(DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0), "/p.json")
                .framing(framing)
                .build()
                .expect("scene should accept it");
        }
    }

    #[test]
    fn framing_off_the_display_is_rejected_by_every_entry_point() {
        let display = DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0);
        for framing in off_the_map_framings() {
            assert!(!framing.is_valid(), "{framing:?} is not a position");
            assert_framing_rejected(framing.validate().expect_err("framing should be refused"));
            assert_framing_rejected(
                SceneDesc::builder(display.clone(), "/p.json")
                    .framing(framing)
                    .build()
                    .expect_err("scene builder should refuse"),
            );
            assert_framing_rejected(
                SceneTemplate::builder("/p.json")
                    .framing(framing)
                    .build()
                    .expect_err("template builder should refuse"),
            );
            assert_framing_rejected(
                SceneDesc::new(display.clone(), "/p.json", "/assets", 60, false)
                    .with_framing(framing)
                    .validate()
                    .expect_err("scene validate should refuse"),
            );
            let mut template = SceneTemplate::builder("/p.json")
                .build()
                .expect("template should build");
            template.framing = framing;
            assert_framing_rejected(template.validate().expect_err("template validate should refuse"));
        }
    }

    #[test]
    fn only_a_different_framing_makes_another_wallpaper() {
        let display = DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0);
        let scene = SceneDesc::new(display.clone(), "/p.json", "/assets", 60, false);

        let moved = scene.clone().with_framing(SceneFraming {
            pan_x: 0.1,
            pan_y: 0.5,
        });
        assert!(!scene.same_wallpaper(&moved));
        assert!(!moved.same_wallpaper(&scene));

        let mut elsewhere = scene.clone();
        elsewhere.display = DisplayDesc::new(2, 1920, 0, 2560, 1440, 2.0);
        elsewhere.paused = true;
        assert!(scene.same_wallpaper(&elsewhere));
        assert!(scene.same_wallpaper(&scene.clone()));
    }

    #[test]
    fn template_round_trip_keeps_framing() {
        let framing = SceneFraming {
            pan_x: 0.2,
            pan_y: 0.9,
        };
        let template = SceneTemplate::builder("/p.json")
            .framing(framing)
            .build()
            .expect("template should build");

        let scene = template.for_display(DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0));
        assert_eq!(scene.framing, framing);
        assert_eq!(SceneTemplate::from_scene_desc(&scene).framing, framing);
        assert_eq!(SceneTemplate::from_scene_desc(&scene), template);
    }

    #[test]
    fn scene_template_rejects_empty_scene_path() {
        let error = SceneTemplate::builder("")
            .build()
            .expect_err("empty path should fail");

        match error {
            EngineError::InvalidInput(message) => {
                assert_eq!(message, "scene_path must not be empty");
            }
            other => panic!("expected invalid input, got {other:?}"),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SceneRenderTargetIr {
    pub width: u32,
    pub height: u32,
}
