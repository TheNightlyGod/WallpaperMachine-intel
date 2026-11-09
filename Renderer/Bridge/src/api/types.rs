/// Player data read by the native host. Artwork is bounded RGBA8, never a path or URL.
#[derive(Clone, Debug, Default, uniffi::Record)]
pub struct BridgeMediaSnapshot {
    pub title: String,
    pub artist: String,
    pub album: String,
    // The host's numbering: 0 playing, 1 paused, 2 stopped. Mapped to the
    // scene's own (stopped 0, playing 1, paused 2) by name in `into_state`.
    // A plain comment: a doc comment would change the generated bindings.
    pub playback_state: u8,
    pub position: f64,
    pub duration: f64,
    pub artwork_width: u32,
    pub artwork_height: u32,
    pub artwork_rgba: Vec<u8>,
}

impl BridgeMediaSnapshot {
    pub(crate) fn into_state(self) -> Result<wallpaper_core::media::MediaPollResult, super::BridgeError> {
        use wallpaper_core::media::{MediaIntegrationEvent as Event, MediaPlaybackState, MediaProperties, MediaPollResult, MediaThumbnailRgba};
        let state = match self.playback_state {
            0 => MediaPlaybackState::Playing,
            1 => MediaPlaybackState::Paused,
            2 => MediaPlaybackState::Stopped,
            _ => return Err(super::BridgeError::invalid_input("invalid media playback state")),
        };
        if !self.position.is_finite() || !self.duration.is_finite() || self.position < 0.0 || self.duration < 0.0 {
            return Err(super::BridgeError::invalid_input("invalid media timeline"));
        }
        let has_artwork = !self.artwork_rgba.is_empty();
        if self.artwork_width > 512 || self.artwork_height > 512 {
            return Err(super::BridgeError::invalid_input("media artwork exceeds 512 pixels"));
        }
        let artwork = MediaThumbnailRgba::new(self.artwork_width, self.artwork_height, self.artwork_rgba)
            .map_err(super::BridgeError::invalid_input)?;
        let mut events = vec![Event::StatusChanged { enabled: true },
            Event::PropertiesChanged(MediaProperties { title: Some(self.title), artist: Some(self.artist), album_title: Some(self.album) }),
            Event::PlaybackChanged { state },
            Event::ThumbnailChanged { has_thumbnail: has_artwork, primary_color: [0.0; 3], text_color: [1.0; 3] }];
        if self.duration > 0.0 {
            events.push(Event::TimelineChanged { duration: self.duration, position: self.position.min(self.duration) });
        }
        Ok(MediaPollResult { events, artwork: Some(artwork) })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeWallpaperKind {
    ProjectScene,
    Video,
    Webpage,
    Unknown,
}

impl From<wallpaper_core::project::WallpaperProjectType> for BridgeWallpaperKind {
    fn from(value: wallpaper_core::project::WallpaperProjectType) -> Self {
        match value {
            wallpaper_core::project::WallpaperProjectType::Scene => Self::ProjectScene,
            wallpaper_core::project::WallpaperProjectType::Video => Self::Video,
            wallpaper_core::project::WallpaperProjectType::Web => Self::Webpage,
            wallpaper_core::project::WallpaperProjectType::Unknown => Self::Unknown,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeScalingMode {
    None,
    Stretch,
    Match,
    Fill,
    /// `Match`'s picture, with the room around it filled by a blurred,
    /// darkened copy of the same picture.
    MatchBlurred,
}

/// Where a wallpaper sits on one display when that display leaves room around
/// it, as a fraction of that room on each axis: `0.0` is left or top, `1.0` is
/// right or bottom, and `0.5` on both is the centred layout every wallpaper
/// has until it is moved. Always a finite fraction between 0 and 1.
#[derive(Clone, Copy, Debug, PartialEq, uniffi::Record)]
pub struct BridgeFraming {
    pub pan_x: f64,
    pub pan_y: f64,
}

impl From<wallpaper_core::project::SceneFraming> for BridgeFraming {
    fn from(framing: wallpaper_core::project::SceneFraming) -> Self {
        Self {
            pan_x: framing.pan_x,
            pan_y: framing.pan_y,
        }
    }
}

impl From<crate::config::FramingCfg> for BridgeFraming {
    /// What the app is told is what the engine is handed, so a saved position
    /// that is not a valid fraction reads the way it plays.
    fn from(framing: crate::config::FramingCfg) -> Self {
        framing.to_scene().into()
    }
}

/// Committed wallpaper inputs for a native lock-screen or screen-saver display.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeLockScreenScene {
    pub display_id: u32,
    /// Stable library id. The app needs it to find the wallpaper's managed
    /// user-asset manifest, which is keyed on the id rather than on the project
    /// path so a Workshop update does not orphan it.
    pub wallpaper_id: String,
    pub title: String,
    pub project_path: String,
    pub assets_path: String,
    pub fps: u32,
    pub scaling_mode: BridgeScalingMode,
    pub scaling_factor: f64,
    /// Where the wallpaper sits on that display. Web wallpapers fill their
    /// page and are always centred.
    pub framing: BridgeFraming,
    /// Flat renderer overrides, or decorated `{id: {value, type, ...}}` web options.
    pub properties_json: Option<String>,
    pub paused: bool,
    /// Wallpaper Engine's per-wallpaper options as saved, for scenes and plain videos; `None`
    /// for web pages, which have none.
    pub engine_options: Option<BridgeEngineOptionValues>,
    /// The scene quality the scene loads with; `None` for videos and web pages.
    pub scene_quality: Option<BridgeSceneQuality>,
    /// A plain video's border colour in Fit-style modes: the project's `schemecolor`
    /// property (WE `sub_1400FFCB0`); `None` when the project has none, which is black.
    pub border_color: Option<BridgeRgb>,
}

/// The window of one open scene wallpaper: the live scene of a display, or
/// one the display keeps loaded and paused for a desktop the person left
/// ([`crate::WallpaperBridge::set_display_parked_wallpapers`]).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeSceneWindow {
    pub display_id: u32,
    pub wallpaper_id: String,
    /// The window server's number for the scene's window.
    pub window_number: i64,
    /// Kept paused rather than shown as the display's live scene.
    pub parked: bool,
    pub ready: bool,
}

/// Host-rendered content to prepare for an unvisited desktop; scenes are prepared by the engine.
#[derive(Clone, Debug, Default, PartialEq, uniffi::Record)]
pub struct BridgeDesktopPreload {
    pub web: Option<BridgeWebWallpaper>,
    pub video: Option<BridgeNativeVideoWallpaper>,
}

/// Committed inputs for a web wallpaper the host renders in a web view on one
/// display. Mirrors of a web source display appear as separate entries.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeWebWallpaper {
    pub display_id: u32,
    /// Reconcile revision to echo when this host finishes its initial load.
    pub startup_revision: u64,
    pub display_key: String,
    /// Source display of this assignment; independent instances of one project remain separate.
    pub audio_source_display_id: u32,
    pub wallpaper_id: String,
    pub title: String,
    /// Absolute project directory.
    pub project_path: String,
    /// Entry page relative to `project_path`.
    pub entry_file: String,
    pub fps: u32,
    /// The internal render scale in force: the saved scale, or the battery
    /// profile's while Reduced quality is selected and the Mac is on battery,
    /// already clamped to `0.25..=1.0`. A web page applies it to
    /// `window.devicePixelRatio`.
    pub render_scale: f32,
    pub paused: bool,
    pub volume: f32,
    pub muted: bool,
    pub audio_response_enabled: bool,
    /// Whether this wallpaper shares system media integration: on by default,
    /// off once the user turns it off for this wallpaper. The host still has to
    /// find a usable system media source; this is only the user's consent to
    /// look.
    pub media_integration_enabled: bool,
    /// Wallpaper Engine `applyUserProperties` payload for every user-editable
    /// property, overrides applied over defaults. Each entry is
    /// `{ "value": …, "type": "<authored kind>" }`, plus `"fileFilter"` on
    /// file and directory properties that declared one and `"mode"` on
    /// directory properties.
    pub properties_json: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeDisplayMode {
    Standalone,
    Mirror,
}

#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum BridgePropertyValue {
    Bool { value: bool },
    Number { value: f64 },
    String { value: String },
    ColorRgb { red: f64, green: f64, blue: f64 },
    Empty,
}

/// One value a host is showing for a property without having saved it, such
/// as a slider the person is still dragging. It is checked like an edit and
/// never becomes one.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgePropertyEdit {
    pub property_id: String,
    pub value: BridgePropertyValue,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgePropertyKind {
    Slider,
    Combo,
    Bool,
    Color,
    TextInput,
    Text,
    Group,
    /// A single user-chosen file.
    File,
    /// A user-chosen folder the page reads.
    Directory,
    /// A scene texture picker: a texture the scene engine resolves, never a
    /// path the host stages or a page opens.
    Texture,
    Unknown,
}

/// Which media a file or directory property accepts.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeFileFilter {
    Image,
    Video,
}

/// How a directory property hands its contents to the page.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeDirectoryMode {
    OnDemand,
    FetchAll,
}

/// One pull of the process-wide audio analysis.
///
/// `bins` is always 128 values: 0..=63 left, 64..=127 right, low index is bass.
///
/// `stereo` describes how the signal was captured, not whether the two halves
/// differ: it is true whenever the tap delivered two channels and two
/// independent analyses ran, which includes content that happens to be
/// identical on both. It is false only for a genuinely mono source, and then
/// the halves are equal and nothing may present that as stereo. Equal halves
/// with `stereo` true are therefore an ordinary state, not a contradiction.
///
/// `generation` only ever increases; an unchanged generation means no new
/// analysis has been produced.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeAudioSpectrum {
    pub generation: u64,
    pub stereo: bool,
    pub bins: Vec<f32>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgePlaybackState {
    Playing,
    Paused,
}

/// What wallpapers do while the machine is on battery.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeBatteryMode {
    KeepRunning,
    ReducedQuality,
    Pause,
}

/// Why the host asks for the reduced-quality profile right now, apart from
/// the battery mode the user saved. Held only while the host reports it; never
/// persisted.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, uniffi::Enum)]
pub enum BridgeQualityThrottleCause {
    /// Low Power Mode is on.
    LowPowerMode,
    /// The Mac reports a thermal state that calls for less work.
    Heat,
    /// The battery is at or below the user's low-battery threshold.
    LowBattery,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeAppSnapshot {
    pub playback_state: BridgePlaybackState,
    pub selected_wallpaper_id: Option<String>,
    pub active_wallpaper_ids: Vec<String>,
    pub errors: Vec<String>,
    /// Wallpapers assigned to a display that were left out of this session
    /// because the app died while opening them in two sessions in a row,
    /// sorted. `BridgeStore` offers each one a retry; Apply clears them too.
    pub held_wallpaper_ids: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeLibraryScanStatus {
    pub scanning: bool,
    pub done: u64,
    pub total: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeWallpaperEntry {
    pub id: String,
    pub title: String,
    pub kind: BridgeWallpaperKind,
    pub supported: bool,
    pub active: bool,
    pub selected: bool,
    pub preview_path: Option<String>,
}

/// Read-only inputs for a host-owned preview. No display assignment or playback state is
/// changed when these are exported. Properties include the current, unapplied draft.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeWallpaperPreview {
    pub wallpaper_id: String,
    pub title: String,
    pub kind: BridgeWallpaperKind,
    pub project_path: String,
    pub entry_file: String,
    pub assets_path: String,
    pub properties_json: String,
    pub fps: u32,
    pub scaling_mode: BridgeScalingMode,
    pub scaling_factor: f64,
    pub volume: f32,
    /// Wallpaper Engine's per-wallpaper options with the draft and the pending
    /// values in them; `None` for a web page.
    pub engine_options: Option<BridgeEngineOptionValues>,
    /// The absolute path of the chosen image filter's `.tex` file, present
    /// only when one is chosen and the file exists.
    pub lut_path: Option<String>,
    /// The saved scene quality settings, for a scene preview.
    pub scene_quality: BridgeSceneQuality,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeLibrarySnapshot {
    pub wallpapers: Vec<BridgeWallpaperEntry>,
    pub scan_status: BridgeLibraryScanStatus,
    pub scene_count: u64,
    pub video_count: u64,
    pub webpage_count: u64,
    pub unknown_count: u64,
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
#[allow(clippy::struct_excessive_bools)]
pub struct BridgeDisplayConfigRow {
    pub display_id: String,
    pub title: String,
    pub enabled: bool,
    pub scaling_mode: BridgeScalingMode,
    pub scaling_factor: f64,
    /// Where the wallpaper sits on this display. Unlike the scale factor it is
    /// never a draft: this is what is saved and what the display shows.
    pub framing: BridgeFraming,
    pub target_fps: u32,
    pub max_fps: u32,
    pub muted: bool,
    pub volume: f32,
    pub dirty: bool,
    pub can_restore_defaults: bool,
}

/// Range and granularity of a slider property.
/// A host draws the control from these numbers.
/// `precision` is the number of decimals to show.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeSliderMetadata {
    pub min: f64,
    pub max: f64,
    pub step: f64,
    pub precision: u32,
}

/// One entry of a combo property: what the user reads and the value stored
/// when it is picked.
/// The value keeps the project's own type, so numeric combos stay numeric.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeComboOption {
    pub label: String,
    pub value: BridgePropertyValue,
}

/// One row of a wallpaper's property editor, with everything a host needs to
/// draw and edit it without reading the project file itself.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgePropertyDescriptor {
    /// The property's key in the project.
    pub id: String,
    /// Which control the property is edited with.
    /// Kinds this build does not know are reported as `Unknown`
    /// instead of being dropped from the list.
    pub kind: BridgePropertyKind,
    /// The label as authored; it may carry HTML markup.
    pub label_html: String,
    /// The current value of the property.
    /// It includes edits that have not been applied yet,
    /// which is why `dirty` exists next to it.
    pub value: BridgePropertyValue,
    /// The value the wallpaper's author shipped, as authored.
    /// Edits never change it; it is what the property is compared
    /// with and returned to.
    pub default_value: BridgePropertyValue,
    /// Present for sliders only.
    pub slider: Option<BridgeSliderMetadata>,
    /// Empty unless the property is a combo.
    pub combo_options: Vec<BridgeComboOption>,
    /// Present on file and directory properties, and only when the project
    /// declared a file-type option.
    pub file_filter: Option<BridgeFileFilter>,
    /// Present on directory properties only.
    pub directory_mode: Option<BridgeDirectoryMode>,
    /// Edited but not applied yet.
    pub dirty: bool,
    /// Reported for the restore-defaults control of the host's editor.
    /// The bridge decides it so that every host offers the action
    /// under the same conditions.
    pub can_restore_defaults: bool,
    /// False while an authored visibility rule hides the property. The row is
    /// still listed, with the value the renderer uses; a rule that cannot be
    /// read never disables a property.
    pub enabled: bool,
    /// File and directory properties: the app keeps its own managed copy of
    /// the property's assets. False for every other kind.
    pub asset_managed: bool,
    /// File and directory properties: the property names something and neither
    /// the user's own path nor a managed copy resolves any more. A property
    /// that is not set is not missing.
    pub asset_missing: bool,
    /// The user's own path, for display; `None` when the property is not set.
    pub asset_source_path: Option<String>,
}

/// The options page of one wallpaper: its properties, where it runs, and its
/// audio switches, as the user sees them before pressing Apply.
#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeWallpaperOptionsSnapshot {
    pub wallpaper_id: String,
    pub title: String,
    /// Scene, video or web page; decides which options exist at all.
    /// Only scenes take property edits.
    /// The rest of the page is the same for every kind.
    pub kind: BridgeWallpaperKind,
    /// Whether the bridge supports applying this wallpaper at all.
    /// A host should not offer Apply for one it does not support.
    /// The reason is not part of this record.
    pub supported: bool,
    /// Edits exist on this page that have not been applied.
    /// They are kept by the bridge, so every host sees the same answer.
    /// Per-property flags are on the rows of `properties`.
    pub dirty: bool,
    pub properties: Vec<BridgePropertyDescriptor>,
    pub display_configurations: Vec<BridgeDisplayConfigRow>,
    pub audio_response_enabled: bool,
    /// The user's consent to look for a system media source for this
    /// wallpaper; on until switched off. It says nothing about whether a
    /// source exists.
    pub media_integration_enabled: bool,
    pub muted: bool,
    pub volume: f32,
    /// Wallpaper Engine's per-wallpaper options for a scene or a video; `None`
    /// for a web page and a wallpaper of unknown kind, which have none.
    pub engine_options: Option<BridgeEngineOptions>,
}

/// One of Wallpaper Engine's per-wallpaper options (the properties
/// `wallpaper64.exe` `sub_140104B60` injects into every scene and video).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum BridgeEngineOptionId {
    ColorEnabled,
    Brightness,
    Contrast,
    Saturation,
    HueShift,
    ImageFilter,
    FilterStrength,
    FlipHorizontal,
    MouseParallax,
    PlaybackRate,
}

/// One row of the per-wallpaper options, drawn like a property row.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeEngineOptionRow {
    pub id: BridgeEngineOptionId,
    /// The current value, pending edits included: `Bool` for a switch,
    /// `Number` for a slider and `String` (a file stem, empty for none) for
    /// the image filter.
    pub value: BridgePropertyValue,
    pub default_value: BridgePropertyValue,
    /// Present for the sliders only.
    pub slider: Option<BridgeSliderMetadata>,
    /// The value differs from the default, like a property's `dirty`.
    pub modified: bool,
    /// False for the colour sliders while the colour switch is off and for the
    /// filter strength while no image filter is chosen. Such a row is listed;
    /// the host decides whether to show it.
    pub enabled: bool,
}

/// The per-wallpaper options of one scene or video, and the image filters the
/// shared assets offer.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeEngineOptions {
    pub rows: Vec<BridgeEngineOptionRow>,
    /// The file stems under the shared assets' `materials/lut`, sorted without
    /// regard to case. A saved filter that is no longer there is not listed.
    pub image_filters: Vec<String>,
}

/// A per-wallpaper option value a host is showing without having saved it,
/// such as a slider being dragged. Checked like an edit and never one.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeEngineOptionEdit {
    pub option: BridgeEngineOptionId,
    pub value: BridgePropertyValue,
}

/// Every per-wallpaper option value at once, for a renderer the host drives
/// itself.
#[allow(clippy::struct_excessive_bools)]
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeEngineOptionValues {
    pub color_enabled: bool,
    pub brightness: f64,
    pub contrast: f64,
    pub saturation: f64,
    pub hue_shift: f64,
    pub image_filter: String,
    pub filter_strength: f64,
    pub flip_horizontal: bool,
    pub mouse_parallax: bool,
    pub playback_rate: f64,
}

impl From<&crate::config::EngineOptionsCfg> for BridgeEngineOptionValues {
    fn from(options: &crate::config::EngineOptionsCfg) -> Self {
        Self {
            color_enabled: options.color_enabled,
            brightness: options.brightness,
            contrast: options.contrast,
            saturation: options.saturation,
            hue_shift: options.hue_shift,
            image_filter: options.image_filter.clone(),
            filter_strength: options.filter_strength,
            flip_horizontal: options.flip_horizontal,
            mouse_parallax: options.mouse_parallax,
            playback_rate: options.playback_rate,
        }
    }
}

impl From<BridgeEngineOptionId> for crate::config::EngineOptionId {
    fn from(id: BridgeEngineOptionId) -> Self {
        use crate::config::EngineOptionId as Id;
        match id {
            BridgeEngineOptionId::ColorEnabled => Id::ColorEnabled,
            BridgeEngineOptionId::Brightness => Id::Brightness,
            BridgeEngineOptionId::Contrast => Id::Contrast,
            BridgeEngineOptionId::Saturation => Id::Saturation,
            BridgeEngineOptionId::HueShift => Id::HueShift,
            BridgeEngineOptionId::ImageFilter => Id::ImageFilter,
            BridgeEngineOptionId::FilterStrength => Id::FilterStrength,
            BridgeEngineOptionId::FlipHorizontal => Id::FlipHorizontal,
            BridgeEngineOptionId::MouseParallax => Id::MouseParallax,
            BridgeEngineOptionId::PlaybackRate => Id::PlaybackRate,
        }
    }
}

impl From<crate::config::EngineOptionId> for BridgeEngineOptionId {
    fn from(id: crate::config::EngineOptionId) -> Self {
        use crate::config::EngineOptionId as Id;
        match id {
            Id::ColorEnabled => Self::ColorEnabled,
            Id::Brightness => Self::Brightness,
            Id::Contrast => Self::Contrast,
            Id::Saturation => Self::Saturation,
            Id::HueShift => Self::HueShift,
            Id::ImageFilter => Self::ImageFilter,
            Id::FilterStrength => Self::FilterStrength,
            Id::FlipHorizontal => Self::FlipHorizontal,
            Id::MouseParallax => Self::MouseParallax,
            Id::PlaybackRate => Self::PlaybackRate,
        }
    }
}

/// One display's line in the monitor-information view.
/// The text fields are ready to show, so the view does no lookups
/// of its own.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeMonitorInfoRow {
    pub display_id: String,
    pub title: String,
    /// The wallpaper shown on this display.
    /// Its title follows in `wallpaper_title`.
    /// The two always describe the same wallpaper.
    pub wallpaper_id: String,
    pub wallpaper_title: String,
    /// Set when this display mirrors another one.
    /// It names the source display by the id the settings rows use,
    /// and `mirror_target_title` carries that display's title.
    pub mirror_target_display_id: Option<String>,
    pub mirror_target_title: Option<String>,
    /// The scaling mode, as text for display.
    /// The settings rows carry the same setting as a typed value
    /// (`BridgeDisplaySettingsRow::scaling_mode`).
    pub scaling_mode: String,
    /// The frame rate in effect, as text for display.
    /// The settings rows carry it as a number
    /// (`BridgeDisplaySettingsRow::target_fps`).
    pub target_fps: String,
    /// Whether the wallpaper on this display reacts to system audio.
    pub audio_response: bool,
}

/// All rows of the monitor-information view.
/// They follow the order of the settings page, so the two views
/// list the displays the same way.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeMonitorInformationSnapshot {
    pub rows: Vec<BridgeMonitorInfoRow>,
}

/// One display's block on the settings page.
/// It holds floats, so it derives `PartialEq` but not `Eq`.
/// The id is what the display mutations take as their first argument.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeDisplaySettingsRow {
    /// The key of the display in the display mutations: "primary", a live
    /// display id, or an identity selector. The settings rows and the
    /// monitor-information rows use the same keys.
    pub display_id: String,
    pub title: String,
    /// Whether wallpapers are shown on this display at all.
    pub enabled: bool,
    /// Standalone shows a wallpaper of its own; Mirror repeats another display.
    pub mode: BridgeDisplayMode,
    /// The display ids this display may be set to mirror.
    /// They use the same keys as `display_id`.
    /// `selected_mirror_target` names the one in use, if any.
    pub mirror_targets: Vec<String>,
    pub selected_mirror_target: Option<String>,
    pub scaling_mode: BridgeScalingMode,
    /// Scale applied on top of the scaling mode; 1.0 is the neutral value.
    /// It must be finite and positive to be accepted.
    /// Changes wait for Apply, like the other scene edits.
    pub scaling_factor: f64,
    /// The frame rate in effect for this display.
    /// The monitor-information view shows it as text
    /// (`BridgeMonitorInfoRow::target_fps`).
    pub target_fps: u32,
    /// The highest frame rate offered for this display.
    /// It is the upper end of the range a host lets the user pick from.
    /// `target_fps` is chosen within it.
    pub max_fps: u32,
    pub muted: bool,
    pub volume: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeLogLevel {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

/// Where the logs are kept and which file is being written.
/// `active_session` names the current run of the app.
/// The size is that of the active file at the time of the read.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeLogStatus {
    pub logs_root: String,
    pub active_session: String,
    pub active_file: String,
    pub active_file_size_bytes: u64,
}

/// Disk use shown on the settings page.
/// The shader cache is the compiled-shader directory.
/// The log status describes the current log file.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeStorageStatus {
    pub shader_cache_size_bytes: u64,
    pub logs: BridgeLogStatus,
}

/// Which renderer is actually playing the video on one display.
///
/// `backend` reports what is running, not what was asked for. `fallback_reason`
/// is present only when the user selected the native player and this display
/// did not get it, so an empty reason on a legacy row means the user never
/// asked rather than that no reason was recorded.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeVideoBackendReport {
    pub display_id: u32,
    pub display_name: String,
    pub wallpaper_id: String,
    pub wallpaper_title: String,
    pub backend: String,
    pub fallback_reason: Option<String>,
}

/// What one running scene wallpaper's update clock is actually doing.
///
/// `mode` composes the renderer's own answer with the host's pause state, in
/// that precedence: a wallpaper the user paused reads `user_paused` whatever
/// the renderer says, a display whose presentation is suspended reads
/// `policy_suspended`, a surface that stopped drawing after a failure reads
/// `stopped_after_failure`, and only then does the renderer's classification
/// show through. A scene that is running but cannot be read reads `unknown` — never
/// `continuous`, because "we could not tell" and "it is definitely ticking"
/// are different facts and only one of them is evidence.
///
/// `reasons` are the inputs the renderer says keep the scene updating, already
/// lowercase snake_case. Empty is a real answer: nothing is demanding updates.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeSceneUpdateModeReport {
    pub display_id: u32,
    pub display_name: String,
    pub wallpaper_id: String,
    pub wallpaper_title: String,
    pub mode: String,
    pub reasons: Vec<String>,
}

/// Whether a renderer is drawing the scene on one display.
///
/// `backend` is `"native_metal"` while Native Metal is drawing it, and
/// `"unknown"` while the scene is still being read or is held in a failure.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeSceneBackendReport {
    pub display_id: u32,
    pub display_name: String,
    pub wallpaper_id: String,
    pub wallpaper_title: String,
    pub backend: String,
    /// Why the scene is held and not drawn, when Native Metal could not draw
    /// it: the stage (`"unsupported"`, `"prepare"`, `"compile"`, `"frame"` or
    /// `"surface"`), a category the host words for the user, and the renderer's
    /// own English explanation for diagnostics. Both are `None` for a scene
    /// that is drawing, and `backend` is `"unknown"` while they are set:
    /// nothing is drawing the scene, and the display shows its last frame or
    /// the project's preview picture.
    pub failure_stage: Option<String>,
    pub failure_reason: Option<String>,
    /// How this scene's video textures reached the shaders that sample them on
    /// the last frame it drew: `"none"`, `"bgra"`, `"nv12_direct"`,
    /// `"nv12_converted"`, `"nv12_mixed"`, `"nv12_converted_preparing"` or
    /// `"yuv10_converted"` (10-bit video, HDR tone mapped to SDR). A read-back,
    /// not a preference: a scene with no video, or one still starting, reports
    /// `"none"`.
    pub video_path: String,
    /// Whether this scene is really running under the saved
    /// `scene_optimization_enabled` value, rather than still carrying the plan
    /// the previous value produced. `None` means the renderer could not say,
    /// which is not the same as "yes".
    pub optimization_applied: Option<bool>,
    /// The scene quality the renderer actually draws: features it does not
    /// draw yet (MSAA, shadows, volumetrics) read off. `None` before the scene
    /// loaded or when the renderer could not say.
    pub quality_in_force: Option<BridgeSceneQuality>,
}

/// MSAA sample count, Wallpaper Engine's words `none` / `x2` / `x4` / `x8`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeMsaa {
    Off,
    X2,
    X4,
    X8,
}

/// Shadow and volumetric quality, Wallpaper Engine's words `disabled` / `low` /
/// `medium` / `high` / `ultra`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgeQualityLevel {
    Off,
    Low,
    Medium,
    High,
    Ultra,
}

/// Post-processing level, Wallpaper Engine's words `disabled` / `enabled` /
/// `ultra` / `displayhdr`. Only Ultra and Display HDR draw HDR bloom.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum BridgePostProcessing {
    Disabled,
    Enabled,
    Ultra,
    DisplayHdr,
}

/// The scene quality settings. Changing them loads running scenes again.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeSceneQuality {
    pub msaa: BridgeMsaa,
    pub shadows: BridgeQualityLevel,
    pub volumetrics: BridgeQualityLevel,
    pub reflections: bool,
    pub post_processing: BridgePostProcessing,
}

impl From<wallpaper_core::project::SceneQuality> for BridgeSceneQuality {
    fn from(quality: wallpaper_core::project::SceneQuality) -> Self {
        use wallpaper_core::project::{PostProcessing, QualityLevel};
        let level = |value: QualityLevel| match value {
            QualityLevel::Off => BridgeQualityLevel::Off,
            QualityLevel::Low => BridgeQualityLevel::Low,
            QualityLevel::Medium => BridgeQualityLevel::Medium,
            QualityLevel::High => BridgeQualityLevel::High,
            QualityLevel::Ultra => BridgeQualityLevel::Ultra,
        };
        Self {
            msaa: match quality.msaa {
                2 => BridgeMsaa::X2,
                4 => BridgeMsaa::X4,
                8 => BridgeMsaa::X8,
                _ => BridgeMsaa::Off,
            },
            shadows: level(quality.shadows),
            volumetrics: level(quality.volumetrics),
            reflections: quality.reflection,
            post_processing: match quality.post_processing {
                PostProcessing::Disabled => BridgePostProcessing::Disabled,
                PostProcessing::Enabled => BridgePostProcessing::Enabled,
                PostProcessing::Ultra => BridgePostProcessing::Ultra,
                PostProcessing::DisplayHdr => BridgePostProcessing::DisplayHdr,
            },
        }
    }
}

impl From<BridgeSceneQuality> for wallpaper_core::project::SceneQuality {
    fn from(quality: BridgeSceneQuality) -> Self {
        use wallpaper_core::project::{PostProcessing, QualityLevel};
        let level = |value: BridgeQualityLevel| match value {
            BridgeQualityLevel::Off => QualityLevel::Off,
            BridgeQualityLevel::Low => QualityLevel::Low,
            BridgeQualityLevel::Medium => QualityLevel::Medium,
            BridgeQualityLevel::High => QualityLevel::High,
            BridgeQualityLevel::Ultra => QualityLevel::Ultra,
        };
        Self {
            msaa: match quality.msaa {
                BridgeMsaa::Off => 0,
                BridgeMsaa::X2 => 2,
                BridgeMsaa::X4 => 4,
                BridgeMsaa::X8 => 8,
            },
            shadows: level(quality.shadows),
            volumetrics: level(quality.volumetrics),
            reflection: quality.reflections,
            post_processing: match quality.post_processing {
                BridgePostProcessing::Disabled => PostProcessing::Disabled,
                BridgePostProcessing::Enabled => PostProcessing::Enabled,
                BridgePostProcessing::Ultra => PostProcessing::Ultra,
                BridgePostProcessing::DisplayHdr => PostProcessing::DisplayHdr,
            },
        }
    }
}

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeSettingsSnapshot {
    pub displays: Vec<BridgeDisplaySettingsRow>,
    pub launch_at_login_available: bool,
    pub launch_at_login_enabled: bool,
    /// The user switched the login item off in System Settings > General >
    /// Login Items. Launch at login is then available but not enabled, and
    /// turning it on from the app cannot help: the user has to allow it there.
    pub launch_at_login_needs_approval: bool,
    pub battery_mode: BridgeBatteryMode,
    /// Debug-level lines are recorded too; see `set_verbose_logging`.
    pub verbose_logging: bool,
    pub git_sha: String,
    pub bridge_version: String,
    pub core_version: String,
    pub shader_pipeline_version: String,
    pub storage: BridgeStorageStatus,
    pub video_backends: Vec<BridgeVideoBackendReport>,
    /// The saved preference for the scene renderer's static-subgraph caching
    /// and copy-pass elimination. On by default. Unlike the video pipeline
    /// fields above this is the preference, not a renderer read-back: the
    /// renderer has no query for it.
    pub scene_optimization_enabled: bool,
    /// The saved preference for whole-scene on-demand updating. Off by
    /// default. A preference, not a read-back: `scene_update_modes` is where
    /// what actually happened shows up.
    pub scene_on_demand_enabled: bool,
    /// The saved preference for bringing a scene drawn below full resolution
    /// back to full size with MetalFX instead of a bilinear stretch. Off by
    /// default. A preference, not a read-back: a scene at render scale 1, or one
    /// whose image MetalFX does not take, is composed the old way.
    pub metalfx_upscaling_enabled: bool,
    /// The saved preference for direct NV12 plane sampling inside native Metal
    /// scenes. Off by default, experimental. A preference, not a read-back:
    /// the `video_path` of each `scene_renderers` row is what actually
    /// happened.
    pub scene_video_plane_sampling_enabled: bool,
    /// The saved preference for SDR display framing: an SDR scene at Display
    /// resolution draws only the part of its canvas-cover layout the display
    /// shows. Off by default, experimental. A preference, not a read-back:
    /// `WALLPAPER_MACHINE_SDR_FRAMING` can override it, and a scene that
    /// cannot be framed (Fit, a zoom below 1, one MetalFX upscales) draws the
    /// whole layout whatever this says.
    pub scene_display_framing_enabled: bool,
    /// `"display"` or `"canvas"`: how many pixels a 2D scene is rasterized
    /// with before the render scale divides them. The saved preference, which
    /// every running 2D scene follows; perspective scenes and plain videos
    /// ignore it.
    pub scene_resolution: String,
    /// The saved scene quality (`[quality.scene]`). Reduced quality never
    /// changes it; each `scene_renderers` row's `quality_in_force` is what
    /// the renderer actually draws.
    pub scene_quality: BridgeSceneQuality,
    /// Live per-scene state read back from the renderer on this rebuild. One
    /// row per running scene wallpaper; an empty vector means no scene
    /// wallpaper is running, and a row reading `unknown` means one is running
    /// and could not be read.
    pub scene_update_modes: Vec<BridgeSceneUpdateModeReport>,
    /// Live per-scene backend read back from the renderer on this rebuild.
    pub scene_renderers: Vec<BridgeSceneBackendReport>,
    /// The directory the app keeps user-imported property assets in. Shown
    /// read-only; it is where the files are, not a setting.
    pub user_assets_path: String,
    /// The internal rasterization scale in force right now, after any power
    /// profile. `preferred_render_scale` is what the user saved.
    pub render_scale: f32,
    pub preferred_render_scale: f32,
    /// Global frame-rate ceiling. `None` means no limit. Saved per-display
    /// rates are not rewritten to this.
    pub frame_rate_cap: Option<u32>,
    pub battery_render_scale: f32,
    pub battery_target_fps: u32,
    pub on_battery_power: bool,
    /// The causes the host has asked the reduced-quality profile for, sorted.
    /// Empty when none holds. Runtime only: a fresh bridge starts without any.
    pub quality_throttle: Vec<BridgeQualityThrottleCause>,
    /// The frame-rate ceiling in force: the stricter of the saved global cap
    /// and the profile's rate while the battery mode or a throttle holds the
    /// profile. `frame_rate_cap` stays the saved global cap.
    pub effective_frame_rate_cap: Option<u32>,
    /// False when nothing running can honour an internal render scale, so the
    /// control describes a preference that changes nothing on screen today.
    pub render_scale_supported: bool,
    /// How many installed wallpapers are muted in their own saved sound
    /// settings. The host's mute of every wallpaper is layered on top and
    /// never written into them, so the panel names these beside it.
    pub muted_wallpaper_count: u32,
}

/// Everything the panel shows, in one answer.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeSnapshotBundle {
    pub app: BridgeAppSnapshot,
    pub library: BridgeLibrarySnapshot,
    /// `None` when no wallpaper is selected or its options cannot be built.
    pub wallpaper_options: Option<BridgeWallpaperOptionsSnapshot>,
    pub monitor_information: BridgeMonitorInformationSnapshot,
    pub settings: BridgeSettingsSnapshot,
}

/// The reply to a wallpaper mutation, carrying the options of the affected
/// wallpaper.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeWallpaperMutationBundle {
    pub app: BridgeAppSnapshot,
    pub library: BridgeLibrarySnapshot,
    pub wallpaper_options: BridgeWallpaperOptionsSnapshot,
    pub monitor_information: BridgeMonitorInformationSnapshot,
    pub settings: BridgeSettingsSnapshot,
}

/// The reply to a display mutation.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeDisplayMutationBundle {
    pub app: BridgeAppSnapshot,
    pub library: BridgeLibrarySnapshot,
    pub monitor_information: BridgeMonitorInformationSnapshot,
    pub settings: BridgeSettingsSnapshot,
}

/// Renderer work counters for one wallpaper surface.
///
/// The fields are split on purpose. `timer_wakeups` through
/// `present_gaps_3plus_vsync` are work this surface alone performs and must
/// stop when nobody can see it.
/// The `video_*` fields describe the decoded source, which may legitimately keep
/// running while one of its consumers is hidden as long as another consumer
/// still presents it.
///
/// Counting is off by default. With it off every value is zero, which means
/// "not recorded", never "no work".
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeRendererSurfaceCounters {
    pub display_id: String,
    /// Renderer scene handle: the surface identity.
    pub surface_id: String,
    /// Renderer object identity. Two wallpapers that reused one display and one
    /// handle have different generations and are never merged.
    pub generation: u64,
    /// Identity of the running decoder instance this surface consumes:
    /// `instance:<n>`, or `unknown` when the surface consumes no decoder or
    /// more than one. Two decoders opened from the same file have different
    /// identities and must never be folded together; a roll-up de-duplicates
    /// source work on this, never on the path.
    pub source_id: String,
    /// Scene source path. A human label for the row, not an identity.
    pub source_path: String,
    /// Live decoder instances this surface consumes.
    pub source_count: u64,
    pub backend: String,
    /// Independent reasons, never collapsed into one flag.
    pub effective_pause_reasons: Vec<String>,
    pub paused: bool,
    pub timer_wakeups: u64,
    pub draw_requests: u64,
    pub draw_ticks_suppressed: u64,
    pub draws_executed: u64,
    pub draws_dropped: u64,
    pub render_submissions: u64,
    pub render_failures: u64,
    pub present_requests: u64,
    /// The submitted frame's fence signalled. Not a display presentation.
    pub gpu_completions: u64,
    pub simulation_ticks: u64,
    /// Frames that ran (the scene ticked) but were not drawn or presented,
    /// because they would have put exactly the pixels already on the surface
    /// back. Neither a dropped draw nor a present request.
    pub presents_skipped_unchanged: u64,
    /// Presented drawables the display reported as shown. Reports arrive a
    /// refresh or two after the request, so a window's count trails
    /// `present_requests` by the frames still in flight.
    pub presented_frames: u64,
    /// Presented drawables the display reported as never shown: replaced by a
    /// newer frame or discarded before any refresh showed them.
    pub presents_dropped: u64,
    /// Time from one shown frame to the next, in refreshes of the display:
    /// one, two, three or more. Zero while `vsync_period_micros` is unknown.
    pub present_gaps_1_vsync: u64,
    pub present_gaps_2_vsync: u64,
    pub present_gaps_3plus_vsync: u64,
    pub tick_interval_micros: u64,
    /// 0 when the content cannot prove how often it changes.
    pub content_period_micros: u64,
    /// Refresh period of the display the present gaps are measured in; 0 when
    /// the renderer could not read it.
    pub vsync_period_micros: u64,
    pub video_decode_outputs: u64,
    pub video_seeks: u64,
    pub video_frames_selected: u64,
    pub video_frames_reused: u64,
    /// Decoded frames superseded before they were ever displayed. A rising
    /// count is how a demand-driven clock is falsified.
    pub video_frames_skipped: u64,
    pub video_selected_generation: u64,
    pub video_conversions: u64,
    pub video_imports: u64,
    /// Bytes of converted video destination textures this surface's texture
    /// cache is keeping alive, and the most it ever kept alive. Gauges, not
    /// running totals, and an allocation ledger over those destination
    /// textures alone: decode pixel buffers, Core Video plane wrappers, the
    /// the drawables the layer hands out are all outside it, so
    /// neither figure is a residency or process-footprint measurement.
    pub video_conversion_live_bytes: u64,
    pub video_conversion_peak_live_bytes: u64,
}

/// One pull of the renderer counters, plus the process-wide values that belong
/// to no single surface.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeRendererCountersReport {
    /// False means counting is off and every value is zero.
    pub recording: bool,
    pub surfaces: Vec<BridgeRendererSurfaceCounters>,
    /// Spectrum generations the analysis worker produced, process-wide.
    pub audio_analysis_deliveries: u64,
    pub audio_accepted_frames: u64,
    /// Scenes that both enable audio response and are not paused for their own
    /// display. Zero means the capture tap has no consumer.
    pub audio_active_consumers: u32,
    /// Whether the surfaces' `presented_frames`, `presents_dropped` and present
    /// gaps come from the display's own reports. Present requests are never
    /// reported as presented frames either way.
    pub presentation_feedback_available: bool,
}

/// What the check after the Mac wakes concluded about one display's scene.
///
/// `outcome` is one of a fixed set of names: `ok` (the scene's frame loop
/// moved), `repaired` (it had stopped and the engine rebuilt its surface),
/// `recovery_pending` (a repair was already under way), `gave_up` (this
/// minute's repair attempts were spent, so the scene stays stopped),
/// `recovery_failed`, and `skipped_paused`, `skipped_not_continuous`,
/// `skipped_unreadable` or `skipped_changed` for a scene that was not probed.
/// The frame counts are the renderer's `frames_completed` at the two readings.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeSurfaceCheck {
    pub display_id: u32,
    pub outcome: String,
    pub frames_before: u64,
    pub frames_after: u64,
}

/// A plain local video, played by the host's own player.
///
/// Every plain video with a resolvable media file appears here; the scene engine is never given
/// one. The player plays a clip at the clip's own frame rate: the frame-rate cap applies to scenes
/// and web wallpapers, so no rate travels with this descriptor and none decides whether the host may
/// take the clip. A file the host cannot play is the host's to report as a failed state of that
/// display (the display keeps its previous picture); nothing else plays it instead.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct BridgeNativeVideoWallpaper {
    pub display_id: u32,
    /// Reconcile revision to echo when this host finishes its initial load.
    pub startup_revision: u64,
    /// Source display of this assignment: a mirror carries its source's, so the host can let one
    /// member of the group be heard. Independent assignments of one clip remain separate.
    pub audio_source_display_id: u32,
    pub wallpaper_id: String,
    pub title: String,
    /// Absolute path to the media file, already containment-checked against the
    /// project directory.
    pub media_path: String,
    /// Identifies the media file this descriptor plays: its path, length and
    /// modification time. Identical for every member of a mirror group. The host
    /// keeps its verdict on the file, and the surface it opened for it, under this
    /// key, so a replaced file is judged afresh and an unchanged one is not read
    /// again.
    pub admission_key: u64,
    /// Where the picture sits on this display when it is larger or smaller than
    /// it, as the saved Position of this wallpaper on this display; centred for a
    /// mirror, as the scene engine draws it. The host places the picture with it.
    pub framing: BridgeFraming,
    /// Presentation suspension or the user's own pause, already combined for
    /// this display by the activation rules.
    pub paused: bool,
    pub volume: f32,
    pub muted: bool,
    pub scaling_mode: BridgeScalingMode,
    pub scaling_factor: f64,
    /// Wallpaper Engine's per-wallpaper options as saved for this wallpaper.
    pub engine_options: BridgeEngineOptionValues,
    /// Absolute path of the chosen image filter's `.tex`, present only when the file exists.
    pub lut_path: Option<String>,
    /// The border colour in Fit-style modes: the project's `schemecolor` property (WE
    /// `sub_1400FFCB0` packs it as the video's border colour); `None` → black.
    pub border_color: Option<BridgeRgb>,
}

/// A colour as authored in a project, 0...1 sRGB red, green and blue.
#[derive(Clone, Copy, Debug, PartialEq, uniffi::Record)]
pub struct BridgeRgb {
    pub red: f32,
    pub green: f32,
    pub blue: f32,
}

impl From<[f32; 3]> for BridgeRgb {
    fn from([red, green, blue]: [f32; 3]) -> Self {
        Self { red, green, blue }
    }
}

/// A file an installed scene names that none of its file systems holds.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeSceneMissingFile {
    /// The layer being built when the file was asked for, as the author named it; empty when none
    /// was.
    pub layer: String,
    /// That layer's object id in the scene file, or -1.
    pub object_id: i32,
    /// The path below the scene's own space, such as `materials/rain.json`.
    pub path: String,
}

/// What reading an installed scene, without drawing it, says about it
/// (`WallpaperBridge::scene_capability`).
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeSceneCapability {
    /// Why the scene could not be read at all, or `None` when it was. Nothing below is known
    /// otherwise.
    pub read_error: Option<String>,
    /// `"unsupported"` or `"compile"` when Native Metal would refuse the scene, `None` when it
    /// would not. A scene it accepts can still fail later, when its shaders are compiled for the
    /// device or its render graph is built.
    pub failure_stage: Option<String>,
    /// The renderer's own English explanation of the refusal.
    pub failure_reason: Option<String>,
    /// At most 64, each once, in the order the parse asked for them.
    pub missing_files: Vec<BridgeSceneMissingFile>,
}

impl From<wallpaper_core::SceneCapabilityProbe> for BridgeSceneCapability {
    fn from(probe: wallpaper_core::SceneCapabilityProbe) -> Self {
        let text = |value: String| (!value.is_empty()).then_some(value);
        Self {
            read_error: text(probe.read_error),
            failure_stage: text(probe.failure_stage),
            failure_reason: text(probe.failure_reason),
            missing_files: probe
                .missing_files
                .into_iter()
                .map(|file| BridgeSceneMissingFile {
                    layer: file.layer,
                    object_id: file.object_id,
                    path: file.path,
                })
                .collect(),
        }
    }
}

/// One `engine.openUserShortcut` request from a running wallpaper.
///
/// `value` is what the wallpaper's user chose for that property, and is the
/// only thing a host may act on: the property's name is the author's, not the
/// user's, so acting on it would be deciding for them.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct BridgeUserShortcut {
    pub scene_handle: u64,
    pub property: String,
    pub value: String,
}
