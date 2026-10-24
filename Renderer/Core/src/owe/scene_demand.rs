//! Live scene update state and renderer-backend selection.
//!
//! These are pull-only readings of what a running scene is actually doing, not
//! diagnostic counters: a settings pane reads them without having to switch
//! counting on, and a reading that could not be taken is `None` rather than a
//! plausible-looking default.

use std::time::Duration;

/// Why a scene still needs its frame clock.
///
/// Mirrors `owe_scene_demand_reason` in the renderer's C header. Hand-rolled
/// rather than pulled from `bitflags` so this crate gains no dependency for
/// fifteen constants, and so the "keep unknown bits" rule below is visible
/// rather than a macro option someone could flip.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct SceneDemandReasons(u32);

impl SceneDemandReasons {
    /// A SceneScript or scripted property value runs every tick.
    pub const SCRIPT: Self = Self(1 << 0);
    /// A scalar, zoom or material-alpha animation is playing.
    pub const ANIMATION: Self = Self(1 << 1);
    /// A particle emitter exists.
    pub const PARTICLES: Self = Self(1 << 2);
    /// A video texture is being advanced.
    pub const VIDEO: Self = Self(1 << 3);
    /// A shader consumes the audio spectrum.
    pub const AUDIO_RESPONSE: Self = Self(1 << 4);
    /// A uniform whose value advances every frame.
    pub const TIME_UNIFORM: Self = Self(1 << 5);
    /// A sprite sheet with more than one frame.
    pub const ANIMATED_SPRITE: Self = Self(1 << 6);
    /// Vertex or index data is re-uploaded per frame.
    pub const DYNAMIC_MESH: Self = Self(1 << 7);
    /// Puppet or skeletal transforms are written per frame.
    pub const PUPPET: Self = Self(1 << 8);
    /// A pass reads a target it also writes.
    pub const FEEDBACK: Self = Self(1 << 9);
    /// A text layer's content comes from a value that re-evaluates itself.
    pub const TEXT_BINDING: Self = Self(1 << 10);
    /// A sound layer exists.
    pub const SOUND: Self = Self(1 << 11);
    /// A node transform or material constant is driven by a bound value.
    pub const NODE_BINDING: Self = Self(1 << 12);
    /// An input the renderer could not account for.
    pub const UNKNOWN_INPUT: Self = Self(1 << 13);
    /// No complete frame has been presented yet.
    pub const NO_FRAME_YET: Self = Self(1 << 14);
    /// A text layer's new layout has not reached a frame yet.
    pub const TEXT_LAYOUT_PENDING: Self = Self(1 << 15);
}

impl core::ops::BitOr for SceneDemandReasons {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

impl core::ops::BitOrAssign for SceneDemandReasons {
    fn bitor_assign(&mut self, rhs: Self) {
        self.0 |= rhs.0;
    }
}

impl SceneDemandReasons {
    /// Builds from a raw renderer bitmask, **keeping** bits this build does not
    /// know about.
    ///
    /// Deliberately not `from_bits_truncate`: dropping an unrecognised bit
    /// would turn "the renderer reported a reason this binary has no name for"
    /// into "this scene has nothing to do", which is the one mistake this
    /// feature must not make.
    #[must_use]
    pub const fn from_raw(bits: u32) -> Self {
        Self(bits)
    }

    /// Raw bitmask, including bits this build has no name for.
    #[must_use]
    pub const fn bits(self) -> u32 {
        self.0
    }

    /// Whether every bit of `other` is set.
    #[must_use]
    pub const fn contains(self, other: Self) -> bool {
        (self.0 & other.0) == other.0
    }

    /// Whether no reason at all is set.
    #[must_use]
    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    /// Lowercase snake_case names, in declaration order.
    ///
    /// A set bit with no name in this build is reported as `unknown_input`, so
    /// a reason can never vanish between the renderer and the panel.
    #[must_use]
    pub fn names(self) -> Vec<&'static str> {
        const NAMED: [(SceneDemandReasons, &str); 16] = [
            (SceneDemandReasons::SCRIPT, "script"),
            (SceneDemandReasons::ANIMATION, "animation"),
            (SceneDemandReasons::PARTICLES, "particles"),
            (SceneDemandReasons::VIDEO, "video"),
            (SceneDemandReasons::AUDIO_RESPONSE, "audio_response"),
            (SceneDemandReasons::TIME_UNIFORM, "time_uniform"),
            (SceneDemandReasons::ANIMATED_SPRITE, "animated_sprite"),
            (SceneDemandReasons::DYNAMIC_MESH, "dynamic_mesh"),
            (SceneDemandReasons::PUPPET, "puppet"),
            (SceneDemandReasons::FEEDBACK, "feedback"),
            (SceneDemandReasons::TEXT_BINDING, "text_binding"),
            (SceneDemandReasons::SOUND, "sound"),
            (SceneDemandReasons::NODE_BINDING, "node_binding"),
            (SceneDemandReasons::UNKNOWN_INPUT, "unknown_input"),
            (SceneDemandReasons::NO_FRAME_YET, "no_frame_yet"),
            (SceneDemandReasons::TEXT_LAYOUT_PENDING, "text_layout_pending"),
        ];

        let mut names = Vec::new();
        for (flag, name) in NAMED {
            if self.contains(flag) {
                names.push(name);
            }
        }
        let known: u32 = NAMED.iter().fold(0, |acc, (flag, _)| acc | flag.0);
        let unnamed = self.0 & !known;
        if unnamed != 0 && !names.contains(&"unknown_input") {
            names.push("unknown_input");
        }
        names
    }
}

/// How a scene is currently being updated.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SceneUpdateMode {
    /// The frame clock runs at its configured cadence.
    Continuous,
    /// The clock is stopped; an event restarts it.
    WaitingForEvent,
    /// The clock is stopped until one known instant.
    WaitingForDeadline,
    /// The clock is stopped by a pause decision rather than by the content.
    ClockStopped,
    /// Not a scene wallpaper, so the question does not apply.
    NotApplicable,
    /// Could not be determined.
    Unknown,
}

impl SceneUpdateMode {
    /// Maps a raw `owe_scene_update_mode`. A negative value means the renderer
    /// had nothing to report and yields `None`, never a real mode.
    #[must_use]
    pub const fn from_raw(raw: i32) -> Option<Self> {
        match raw {
            0 => Some(Self::Continuous),
            1 => Some(Self::WaitingForEvent),
            2 => Some(Self::WaitingForDeadline),
            3 => Some(Self::ClockStopped),
            4 => Some(Self::NotApplicable),
            5 => Some(Self::Unknown),
            _ => None,
        }
    }

    /// Stable lowercase name used by the host and the panel.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Continuous => "continuous",
            Self::WaitingForEvent => "waiting_for_event",
            Self::WaitingForDeadline => "waiting_for_deadline",
            Self::ClockStopped => "clock_stopped",
            Self::NotApplicable => "not_applicable",
            Self::Unknown => "unknown",
        }
    }
}

/// The renderer that draws a scene. Native Metal is the only one.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SceneBackend {
    /// The native Metal backend.
    NativeMetal,
}

impl SceneBackend {
    /// Maps a raw `owe_scene_backend`; negative or unknown means not reported.
    #[must_use]
    pub const fn from_raw(raw: i32) -> Option<Self> {
        match raw {
            1 => Some(Self::NativeMetal),
            _ => None,
        }
    }

    /// Stable lowercase name used by the host and the panel.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NativeMetal => "native_metal",
        }
    }
}

/// How many pixels a 2D scene is rasterized with, before the internal render
/// scale divides them.
///
/// A scene with an authored canvas has the choice; a perspective scene already
/// rasterizes at the output size and a plain video keeps its frame's own size,
/// so neither reads it. Either way the canvas stays the source of layout,
/// cursor mapping and every coordinate a script sees: only the render targets'
/// pixel sizes differ.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum SceneResolution {
    /// The authored canvas, whatever the display is. The picture is stretched
    /// to the display when it is presented, which is the cheapest choice and
    /// the softest on a display with more pixels than the canvas.
    #[default]
    Canvas,
    /// The size the canvas is presented at on the display, which is what
    /// Wallpaper Engine rasterizes.
    Display,
}

impl SceneResolution {
    /// Raw value for `owe_set_scene_resolution`.
    #[must_use]
    pub const fn as_raw(self) -> i32 {
        match self {
            Self::Canvas => 0,
            Self::Display => 1,
        }
    }

    /// Stable lowercase name used by config and the panel.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Canvas => "canvas",
            Self::Display => "display",
        }
    }
}

/// One running scene's live update state and backend.
///
/// `update_mode` and `backend` are `Option` because "running but not readable"
/// and "idle" are different facts. A caller that cannot tell reports that it
/// cannot tell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SceneRuntimeReport {
    /// Display this scene is presenting on.
    pub display_id: u32,
    /// Engine handle, so a caller can correlate with its own scene list.
    pub handle: u64,
    /// `None` when the renderer reported nothing.
    pub update_mode: Option<SceneUpdateMode>,
    /// Why the scene still needs its clock.
    pub demand_reasons: SceneDemandReasons,
    /// `None` when the renderer reported nothing.
    pub backend: Option<SceneBackend>,
    /// Why the scene is held and not drawn: Native Metal is the only renderer
    /// and cannot draw it. `backend` is `None` while this is set: nothing is
    /// drawing the scene.
    pub failure: Option<SceneFailure>,
    /// How this scene's video textures reached the shaders sampling them on the
    /// last frame it drew.
    pub video_path: SceneVideoPath,
    /// Whether this scene's compiled graph is running under the current scene
    /// optimisation setting. `None` when the renderer could not say.
    pub optimization_applied: Option<bool>,
    /// Whether this scene's frame loop is alive and whether it stopped after a
    /// failure. `None` when the renderer returned no reading, which is not the
    /// same as a healthy surface.
    pub surface: Option<SurfaceHealth>,
}

/// What stopped a scene from being drawn.
///
/// Mirrors `owe_scene_failure_stage`: a category the host words for the user in
/// their language, shown beside the renderer's own explanation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SceneFailureStage {
    /// The scene uses something the native backend does not support: a refused
    /// admission, found before any renderer was created.
    Unsupported,
    /// The native renderer could not be created on the surface.
    Prepare,
    /// The scene's shaders or pipelines did not compile for Metal.
    Compile,
    /// A frame failed after the scene was set up.
    Frame,
    /// The surface could not be re-established after a display change.
    Surface,
}

impl SceneFailureStage {
    /// Maps a raw `owe_scene_failure_stage`. Zero is no failure, and a value
    /// this build does not name yields `None` as well: the renderer is linked
    /// from the same header as this crate.
    #[must_use]
    pub const fn from_raw(raw: i32) -> Option<Self> {
        match raw {
            1 => Some(Self::Unsupported),
            2 => Some(Self::Prepare),
            3 => Some(Self::Compile),
            4 => Some(Self::Frame),
            5 => Some(Self::Surface),
            _ => None,
        }
    }

    /// Stable lowercase name used by the bridge and logs.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Unsupported => "unsupported",
            Self::Prepare => "prepare",
            Self::Compile => "compile",
            Self::Frame => "frame",
            Self::Surface => "surface",
        }
    }
}

/// Why a scene is held instead of drawn: the stage, and the renderer's own
/// English explanation for diagnostics.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SceneFailure {
    pub stage: SceneFailureStage,
    pub reason: String,
}

/// Why a scene surface stopped drawing although nobody asked it to.
///
/// Mirrors `owe_surface_stop_reason`. A running surface has no stop reason at
/// all, which is why this is never a variant of its own: "not stopped" is
/// `None` where it is carried.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SurfaceStopReason {
    /// A frame failed after the graph was built: the swapchain, an acquire, a
    /// present or a submit. The graph itself is intact.
    FrameFailed,
    /// The render graph or the backend under it could not be built or released,
    /// so there is nothing to draw with until a scene or surface is installed
    /// again.
    GraphFailed,
}

impl SurfaceStopReason {
    /// Maps a raw `owe_surface_stop_reason`. Zero is a surface that is not
    /// stopped, and a value this build does not name yields `None` as well: the
    /// renderer is linked from the same header as this crate, so an unnamed
    /// value is not a newer renderer, only a corrupt reading.
    #[must_use]
    pub const fn from_raw(raw: u32) -> Option<Self> {
        match raw {
            1 => Some(Self::FrameFailed),
            2 => Some(Self::GraphFailed),
            _ => None,
        }
    }

    /// Stable lowercase name for logs.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::FrameFailed => "frame_failed",
            Self::GraphFailed => "graph_failed",
        }
    }
}

/// One reading of a scene surface's frame loop.
///
/// Always on and pull-only, unlike the renderer's work counters. Liveness is
/// `frames_completed` advancing: a frame that would repeat the picture
/// completes without presenting, so `frames_presented` and `last_present_age`
/// stand still on a healthy, still scene and are diagnostics, not a signal.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SurfaceHealth {
    /// Frames the render loop ran to the end, presented or not.
    pub frames_completed: u64,
    /// Frames that reached the surface.
    pub frames_presented: u64,
    /// Frames lost to a failure inside the draw. Never reset by the renderer.
    pub failed_frames: u64,
    /// Time since the last present; `None` before the first one.
    pub last_present_age: Option<Duration>,
    /// Set while the surface is stopped by a failure.
    pub stop: Option<SurfaceStopReason>,
}

impl SurfaceHealth {
    /// Builds from the renderer's raw fields. `u64::MAX` is the renderer's
    /// "never presented" and becomes `None` instead of an age of half a billion
    /// years.
    #[must_use]
    pub const fn from_raw(
        frames_completed: u64,
        frames_presented: u64,
        failed_frames: u64,
        last_present_age_ms: u64,
        stop_reason: u32,
    ) -> Self {
        Self {
            frames_completed,
            frames_presented,
            failed_frames,
            last_present_age: if last_present_age_ms == u64::MAX {
                None
            } else {
                Some(Duration::from_millis(last_present_age_ms))
            },
            stop: SurfaceStopReason::from_raw(stop_reason),
        }
    }
}

/// How a scene's video textures reached the shaders that sample them.
///
/// A report, never a request. `None` covers a scene with no video, one that has
/// drawn nothing yet, and one on a backend with only a single video path.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum SceneVideoPath {
    /// Nothing observed.
    #[default]
    None,
    /// A BGRA frame, imported zero-copy and sampled as one image.
    Bgra,
    /// NV12 planes, sampled directly, with no colour conversion produced.
    Nv12Direct,
    /// NV12 converted once into one image every consumer samples.
    Nv12Converted,
    /// Both, for one scene whose consumers or textures differ.
    Nv12Mixed,
    /// Converted, with the optional direct program still being prepared. The
    /// wallpaper is playing; only the second program is still coming.
    Nv12ConvertedPreparing,
    /// 10-bit video converted once into one image: HDR tone mapped to SDR, or
    /// 10-bit SDR carried over. Its planes are never sampled directly.
    Yuv10Converted,
}

impl SceneVideoPath {
    /// Maps the renderer's own enumerator. An unknown value reads as `None`
    /// rather than as a path this build happens to know.
    #[must_use]
    pub const fn from_raw(value: i32) -> Self {
        match value {
            1 => Self::Bgra,
            2 => Self::Nv12Direct,
            3 => Self::Nv12Converted,
            4 => Self::Nv12Mixed,
            5 => Self::Nv12ConvertedPreparing,
            6 => Self::Yuv10Converted,
            _ => Self::None,
        }
    }

    /// The stable name the settings surface shows.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Bgra => "bgra",
            Self::Nv12Direct => "nv12_direct",
            Self::Nv12Converted => "nv12_converted",
            Self::Nv12Mixed => "nv12_mixed",
            Self::Nv12ConvertedPreparing => "nv12_converted_preparing",
            Self::Yuv10Converted => "yuv10_converted",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_resolution_values_are_the_ones_the_renderer_header_declares() {
        use crate::owe::sys;
        assert_eq!(
            SceneResolution::Canvas.as_raw(),
            sys::owe_scene_resolution_OWE_SCENE_RESOLUTION_CANVAS as i32
        );
        assert_eq!(
            SceneResolution::Display.as_raw(),
            sys::owe_scene_resolution_OWE_SCENE_RESOLUTION_DISPLAY as i32
        );
        assert_eq!(SceneResolution::default(), SceneResolution::Canvas);
    }

    #[test]
    fn an_unrecognised_reason_bit_is_kept_and_named() {
        // A renderer newer than this binary must not look like a still scene.
        let reasons = SceneDemandReasons::from_raw(1 << 30);
        assert!(!reasons.is_empty());
        assert_eq!(reasons.names(), vec!["unknown_input"]);
    }

    #[test]
    fn names_are_lowercase_snake_case_in_declaration_order() {
        let reasons = SceneDemandReasons::VIDEO | SceneDemandReasons::SCRIPT;
        assert_eq!(reasons.names(), vec!["script", "video"]);
    }

    #[test]
    fn no_reasons_is_distinct_from_an_unreadable_scene() {
        assert!(SceneDemandReasons::default().names().is_empty());
        assert_eq!(SceneUpdateMode::from_raw(-1), None);
        assert_eq!(SceneBackend::from_raw(-1), None);
    }

    #[test]
    fn a_raw_mode_outside_the_enumeration_is_not_invented() {
        assert_eq!(SceneUpdateMode::from_raw(99), None);
        assert_eq!(SceneBackend::from_raw(7), None);
    }

    #[test]
    fn text_still_being_laid_out_is_its_own_reason_not_an_unknown_input() {
        // A text layer whose new image has not reached a frame keeps the clock
        // running. Reported under its own name so the panel does not tell the
        // user the renderer failed to account for something.
        let reasons = SceneDemandReasons::TEXT_LAYOUT_PENDING;
        assert_eq!(reasons.names(), vec!["text_layout_pending"]);
        assert!(!reasons.names().contains(&"unknown_input"));
    }

    #[test]
    fn a_stop_reason_the_renderer_names_is_kept_and_anything_else_is_not_invented() {
        assert_eq!(SurfaceStopReason::from_raw(1), Some(SurfaceStopReason::FrameFailed));
        assert_eq!(SurfaceStopReason::from_raw(2), Some(SurfaceStopReason::GraphFailed));
        assert_eq!(
            SurfaceStopReason::from_raw(0),
            None,
            "zero is a surface that is not stopped"
        );
        assert_eq!(
            SurfaceStopReason::from_raw(3),
            None,
            "an unnamed value must not be read as a failure this build can describe"
        );
        assert_eq!(SurfaceStopReason::from_raw(u32::MAX), None);
    }

    #[test]
    fn a_surface_that_never_presented_has_no_present_age() {
        let health = SurfaceHealth::from_raw(12, 0, 0, u64::MAX, 0);
        assert_eq!(
            health.last_present_age, None,
            "the renderer's never-presented marker is not a duration"
        );
        assert_eq!(health.frames_completed, 12);
        assert_eq!(health.stop, None);

        let presented = SurfaceHealth::from_raw(12, 3, 0, 1_500, 0);
        assert_eq!(presented.last_present_age, Some(Duration::from_millis(1_500)));
    }

    #[test]
    fn the_failure_count_survives_a_cleared_stop() {
        // The renderer never resets it, so a host can tell a surface that
        // failed once from one that never has even after it recovered.
        let recovered = SurfaceHealth::from_raw(900, 900, 2, 16, 0);
        assert_eq!(recovered.stop, None);
        assert_eq!(recovered.failed_frames, 2);
    }

    #[test]
    fn every_video_path_the_renderer_can_report_has_its_own_name() {
        // Including the one that says a wallpaper is playing normally while an
        // optional program is still being prepared: folding it into the plain
        // converting path would tell a user "this content will not use direct
        // sampling" when the answer is "not yet".
        let named: Vec<&str> = (0..=6).map(|raw| SceneVideoPath::from_raw(raw).name()).collect();
        assert_eq!(named, vec![
            "none",
            "bgra",
            "nv12_direct",
            "nv12_converted",
            "nv12_mixed",
            "nv12_converted_preparing",
            "yuv10_converted",
        ]);
        // The two ends agree on the numbers: the header's enumerators are what
        // the renderer returns, and these are what the host reads them as.
        use crate::owe::sys;
        for (path, raw) in [
            (SceneVideoPath::Bgra, sys::owe_scene_video_path_OWE_SCENE_VIDEO_PATH_BGRA),
            (SceneVideoPath::Nv12Direct, sys::owe_scene_video_path_OWE_SCENE_VIDEO_PATH_NV12_DIRECT),
            (SceneVideoPath::Nv12Converted, sys::owe_scene_video_path_OWE_SCENE_VIDEO_PATH_NV12_CONVERTED),
            (SceneVideoPath::Nv12Mixed, sys::owe_scene_video_path_OWE_SCENE_VIDEO_PATH_NV12_MIXED),
            (
                SceneVideoPath::Nv12ConvertedPreparing,
                sys::owe_scene_video_path_OWE_SCENE_VIDEO_PATH_NV12_CONVERTED_PREPARING,
            ),
            (SceneVideoPath::Yuv10Converted, sys::owe_scene_video_path_OWE_SCENE_VIDEO_PATH_YUV10_CONVERTED),
        ] {
            assert_eq!(SceneVideoPath::from_raw(raw as i32), path);
        }
        // A renderer newer than this binary must not be read as a path this
        // build happens to know.
        assert_eq!(SceneVideoPath::from_raw(7), SceneVideoPath::None);
    }
}
