use crate::{
    api::{
        BridgeAppSnapshot, BridgeDisplayMode, BridgeDisplayMutationBundle,
        BridgeError, BridgeLibrarySnapshot, BridgeLockScreenScene,
        BridgeMonitorInformationSnapshot, BridgePlaybackState, BridgePropertyEdit, BridgePropertyValue,
        BridgeNativeVideoWallpaper, BridgeQualityThrottleCause, BridgeRendererCountersReport,
        BridgeScalingMode, BridgeSettingsSnapshot, BridgeSnapshotBundle, BridgeWallpaperEntry,
        BridgeWallpaperKind, BridgeWallpaperMutationBundle, BridgeWallpaperOptionsSnapshot,
        BridgeWebWallpaper,
    },
    config::{
        SceneResolutionCfg, WallpaperConfig,
    },
    power::PowerSource,
};

pub struct Bootstrap;

pub struct GetSceneMediaWallpapers;
pub struct UpdateSceneMedia {
    pub wallpaper_id: String,
    pub state: wallpaper_core::media::MediaPollResult,
}

pub struct GetAllSnapshots;

pub struct GetAppSnapshot;

pub struct GetLibrarySnapshot;

pub struct GetLockScreenScenes;

pub struct GetWallpaperPreview {
    pub wallpaper_id: String,
    pub display_id: String,
    /// Values shown without being saved, made to the draft for this export only.
    pub pending: Vec<BridgePropertyEdit>,
}

pub struct GetWebWallpapers;

/// Asks for the monitor-information view: one row per display with the
/// wallpaper it shows, how it is scaled, its frame rate, and the display it
/// mirrors, if any.
pub struct GetMonitorInformationSnapshot;

/// Asks for the settings page state: the display rows, launch at login,
/// logging, storage use and the renderer's backend reports. Reading it also
/// drops the cached shader-cache measurement, so the size is read afresh.
pub struct GetSettingsSnapshot;

/// Empties the shader cache directory and rebuilds the running scenes with a
/// forced shader refresh. The reply is the settings state afterwards, with
/// the cache size measured again.
pub struct ClearShaderCache;

/// Asks for the editable options of one wallpaper: its properties, the
/// per-display switches and the audio switches, with edits not yet applied.
pub struct GetWallpaperOptionsSnapshot {
    pub wallpaper_id: String,
}

/// Test hook: adds a library entry of the given kind without scanning disk.
/// Tests that need real project files put them under a temporary
/// library root and scan it.
pub struct InjectWallpaperForTest {
    pub id: String,
    pub title: String,
    pub kind: BridgeWallpaperKind,
}

pub struct InjectSceneWallpaperConfigForTest {
    pub id: String,
    pub title: String,
}

pub struct InjectSceneProjectForTest {
    pub id: String,
    pub title: String,
    pub project_json: String,
}

pub struct InjectDisplayForTest {
    pub display_id: String,
    pub title: String,
}

pub struct ReplaceLibraryForTest {
    pub entries: Vec<BridgeWallpaperEntry>,
}

pub struct ReplaceWallpaperConfigForTest {
    pub id: String,
    pub config: WallpaperConfig,
}

pub struct SelectWallpaper {
    pub id: String,
}

pub struct RefreshLibrary;

pub struct RefreshDisplays;

/// Opens a wallpaper that the load journal holds back, at the user's request.
pub struct ReleaseHeldWallpaper {
    pub wallpaper_id: String,
}

pub struct PollMousePosition;

pub struct SetFilter {
    pub kind: BridgeWallpaperKind,
    pub enabled: bool,
}

pub struct SetDisplayEnabled {
    pub display_id: String,
    pub enabled: bool,
}

pub struct SetDisplayMode {
    pub display_id: String,
    pub mode: BridgeDisplayMode,
}

pub struct SetMirrorTarget {
    pub display_id: String,
    pub target_display_id: String,
}

pub struct SetMirrorScalingMode {
    pub display_id: String,
    pub mode: BridgeScalingMode,
}

pub struct SetMirrorScalingFactor {
    pub display_id: String,
    pub factor: f64,
}

pub struct SetMirrorTargetFps {
    pub display_id: String,
    pub fps: u32,
}

pub struct SetMirrorVolume {
    pub display_id: String,
    pub volume: f32,
}

pub struct SetMirrorMuted {
    pub display_id: String,
    pub muted: bool,
}

pub struct EjectWallpaperFromDisplay {
    pub display_id: String,
    pub wallpaper_id: String,
}

pub struct SetGlobalPlayback {
    pub playback_state: BridgePlaybackState,
}

pub struct Shutdown;

pub struct SetVolume {
    pub wallpaper_id: String,
    pub volume: f32,
}

pub struct SetMuted {
    pub wallpaper_id: String,
    pub muted: bool,
}

pub struct SetAudioResponseEnabled {
    pub wallpaper_id: String,
    pub enabled: bool,
}

pub struct SetDisplayConfigEnabled {
    pub wallpaper_id: String,
    pub display_id: String,
    pub enabled: bool,
}

pub struct SetScalingMode {
    pub wallpaper_id: String,
    pub display_id: String,
    pub mode: BridgeScalingMode,
}

pub struct SetScalingFactor {
    pub wallpaper_id: String,
    pub display_id: String,
    pub factor: f64,
}

/// Moves a wallpaper on one display. An axis left as `None` keeps its saved
/// value.
pub struct SetDisplayPosition {
    pub wallpaper_id: String,
    pub display_id: String,
    pub pan_x: Option<f64>,
    pub pan_y: Option<f64>,
}

/// Shows a wallpaper at a position on one display while a drag toward it is
/// under way. Nothing is saved; an axis left as `None` keeps its saved value.
pub struct PreviewDisplayPosition {
    pub wallpaper_id: String,
    pub display_id: String,
    pub pan_x: Option<f64>,
    pub pan_y: Option<f64>,
}

/// Shows a wallpaper's pending property edits on every scene that draws it
/// (`show`), or puts back what is saved (`!show`). Nothing is saved.
pub struct PreviewWallpaperProperties {
    pub wallpaper_id: String,
    pub show: bool,
    /// Values shown without being saved, made to the draft for this call only.
    pub pending: Vec<BridgePropertyEdit>,
}

pub struct SetTargetFps {
    pub wallpaper_id: String,
    pub display_id: String,
    pub fps: u32,
}

pub struct SetLaunchAtLogin {
    pub enabled: bool,
}

pub struct SetBatteryMode {
    pub mode: crate::config::BatteryModeCfg,
}

pub struct SetVerboseLogging {
    pub enabled: bool,
}

pub struct SetPresentationSuspended {
    pub suspended: bool,
}

pub struct SetDisplayPresentationSuspended {
    pub display_id: String,
    pub suspended: bool,
}

pub struct SetPresentationUnloaded {
    pub unloaded: bool,
}

pub struct SetDisplayParkedWallpapers {
    pub display_id: String,
    pub wallpaper_ids: Vec<String>,
}

pub struct SetAudioSuppressed {
    pub suppressed: bool,
}

pub struct SetLabelLanguages {
    pub locales: Vec<String>,
}

pub struct SetRendererCountersEnabled {
    pub enabled: bool,
}

pub struct RendererCounters;

pub struct SetSceneResolution {
    pub resolution: SceneResolutionCfg,
}

pub struct SetRenderScale {
    pub scale: f32,
}

pub struct SetFrameRateCap {
    pub cap: Option<u32>,
}

pub struct SetQualityThrottle {
    pub causes: Vec<BridgeQualityThrottleCause>,
}

pub struct SetBatteryQualityProfile {
    pub render_scale: f32,
    pub target_fps: u32,
}

pub struct SetSceneOptimizationEnabled {
    pub enabled: bool,
}

pub struct SetSceneOnDemandEnabled {
    pub enabled: bool,
}

pub struct SetSceneVideoPlaneSamplingEnabled {
    pub enabled: bool,
}

/// A web page registered or dropped its audio listener.
pub struct SetWebAudioSubscribed {
    pub wallpaper_id: String,
    pub display_id: u32,
    pub subscribed: bool,
}

/// Live scenes whose renderers started or stopped reading system audio. The
/// handler re-reads each one's current requirement rather than trusting an
/// order of events, so coalesced deliveries are safe.
pub struct AudioRequirementChanged {
    pub handles: Vec<wallpaper_core::project::SceneHandle>,
}

pub struct SetMediaIntegrationEnabled {
    pub wallpaper_id: String,
    pub enabled: bool,
}

/// Delivers one already-serialized SceneScript media event to every desktop
/// scene that opted in.
pub struct FanOutSystemMediaEvent {
    pub json: String,
}

/// Uploads `$mediaThumbnail` RGBA to every opted-in desktop scene.
pub struct FanOutSystemMediaArtwork {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Asks which applied desktop scenes should be fed now-playing right now.
///
/// The host reads the system player only while something would receive it, so
/// an empty answer is what keeps a machine with the setting off — or one whose
/// wallpapers are all paused or suspended — from being asked for Automation
/// permission and from running the adapter. The handles themselves matter too:
/// a scene that has just been created starts with no media state, and the host
/// can only know to replay for it by seeing a handle it has not fed.
pub struct GetSystemMediaSceneHandles;

/// Asks which applied desktop scenes their user allowed near media at all.
///
/// Distinct from `GetSystemMediaSceneHandles`, which answers "should this be
/// receiving media now" and therefore shrinks when playback stops. Consent does
/// not shrink: a wallpaper whose button press is on its way must be judged on
/// what its user permitted, not on whether it happens to be presenting.
pub struct GetSystemMediaConsentHandles;

/// Stores the absolute path the host staged for a file or directory property,
/// or clears it. The path is persisted exactly as given.
pub struct SetPropertyPath {
    pub wallpaper_id: String,
    pub property_id: String,
    pub path: Option<String>,
}

pub struct GetNativeVideoWallpapers;

pub struct SetPowerSource {
    pub source: PowerSource,
    pub initial_sample: bool,
}

pub struct InitialFrameReady;

pub struct ReportHostWallpaperStartup {
    pub display_id: u32,
    pub wallpaper_id: String,
    pub startup_revision: u64,
    pub native_admission_key: Option<u64>,
    pub ready: bool,
}

pub struct EditProperty {
    pub wallpaper_id: String,
    pub property_id: String,
    pub value: BridgePropertyValue,
}

pub struct RestorePropertyDefault {
    pub wallpaper_id: String,
    pub property_id: String,
}

pub struct RestoreAllPropertyDefaults {
    pub wallpaper_id: String,
}

pub struct ApplyWallpaperOptions {
    pub wallpaper_id: String,
    /// The user chose this (Apply, a click on a tile, Try again), as opposed
    /// to a playlist, a rule or a schedule moving a display. Only the user's
    /// apply lifts the load journal's hold on the wallpaper.
    pub user_initiated: bool,
}

pub struct CancelWallpaperOptions {
    pub wallpaper_id: String,
}

pub struct CompleteAudioResponse {
    pub wallpaper_id: String,
    pub previous_enabled: bool,
    pub result: Result<(), BridgeError>,
}

// Replies that answer with the whole panel state. They are one type under
// several names so a handler's signature says which request it serves, and a
// change to what "everything" means is made in exactly one place.
pub type AllSnapshotsReply = Result<BridgeSnapshotBundle, BridgeError>;
pub type BootstrapReply = AllSnapshotsReply;
pub type SelectWallpaperReply = AllSnapshotsReply;
pub type RefreshLibraryReply = AllSnapshotsReply;
pub type RefreshDisplaysReply = AllSnapshotsReply;

// More replies of the same kind: requests that change shared state and hand
// the refreshed panel back in the same answer.
pub type ReleaseHeldWallpaperReply = AllSnapshotsReply;
pub type SetFilterReply = AllSnapshotsReply;
pub type SetGlobalPlaybackReply = AllSnapshotsReply;

// Reads that return one slice of the state. Each is a separate message so the
// panel can refresh only the part it shows without paying for the rest.
pub type AppSnapshotReply = Result<BridgeAppSnapshot, BridgeError>;
pub type LibrarySnapshotReply = Result<BridgeLibrarySnapshot, BridgeError>;
pub type MonitorInformationSnapshotReply = Result<BridgeMonitorInformationSnapshot, BridgeError>;
pub type SettingsSnapshotReply = Result<BridgeSettingsSnapshot, BridgeError>;
pub type WallpaperOptionsSnapshotReply = Result<BridgeWallpaperOptionsSnapshot, BridgeError>;

// Replies for the lock screen and web wallpapers, which are listed apart from
// the library because their hosts consume them through other channels.
pub type LockScreenScenesReply = Result<Vec<BridgeLockScreenScene>, BridgeError>;
pub type WebWallpapersReply = Result<Vec<BridgeWebWallpaper>, BridgeError>;
pub type ClearShaderCacheReply = Result<BridgeSettingsSnapshot, BridgeError>;

// Replies that carry no data, only whether the request succeeded, plus the
// display mutation bundle (no wallpaper options: a display change has none).
pub type TestMutationReply = Result<(), BridgeError>;
pub type PollMousePositionReply = Result<(), BridgeError>;
pub type DisplayMutationReply = Result<BridgeDisplayMutationBundle, crate::api::BridgeError>;
pub type SetBatteryModeReply = AllSnapshotsReply;
pub type SetVerboseLoggingReply = AllSnapshotsReply;
pub type SetPresentationSuspendedReply = Result<(), BridgeError>;
pub type SetDisplayPresentationSuspendedReply = Result<(), BridgeError>;
pub type SetDisplayParkedWallpapersReply = Result<(), BridgeError>;
pub type SetPresentationUnloadedReply = AllSnapshotsReply;
pub type SetAudioSuppressedReply = AllSnapshotsReply;
pub type SetLabelLanguagesReply = Result<(), BridgeError>;
pub type SetPowerSourceReply = AllSnapshotsReply;
pub type InitialFrameReadyReply = AllSnapshotsReply;
pub type ShutdownReply = Result<(), BridgeError>;
pub type WallpaperMutationReply = Result<BridgeWallpaperMutationBundle, crate::api::BridgeError>;
pub type SetRendererCountersEnabledReply = Result<(), BridgeError>;
pub type RendererCountersReply = Result<BridgeRendererCountersReport, BridgeError>;
pub type SetRenderScaleReply = AllSnapshotsReply;
pub type SetFrameRateCapReply = AllSnapshotsReply;
pub type SetQualityThrottleReply = AllSnapshotsReply;
pub type SetBatteryQualityProfileReply = AllSnapshotsReply;
pub type SetSceneOptimizationEnabledReply = AllSnapshotsReply;
pub type SetSceneResolutionReply = AllSnapshotsReply;
pub type SetSceneOnDemandEnabledReply = AllSnapshotsReply;
pub type SetSceneVideoPlaneSamplingEnabledReply = AllSnapshotsReply;
pub type SetWebAudioSubscribedReply = Result<(), BridgeError>;
pub type AudioRequirementChangedReply = Result<(), BridgeError>;
pub type SetMediaIntegrationEnabledReply = WallpaperMutationReply;
pub type FanOutSystemMediaEventReply = Result<(), BridgeError>;
pub type FanOutSystemMediaArtworkReply = Result<(), BridgeError>;
pub type GetSystemMediaSceneHandlesReply = Result<Vec<u64>, BridgeError>;
pub type GetSystemMediaConsentHandlesReply = Result<Vec<u64>, BridgeError>;
pub type SetPropertyPathReply = WallpaperMutationReply;
pub type GetNativeVideoWallpapersReply = Result<Vec<BridgeNativeVideoWallpaper>, BridgeError>;
