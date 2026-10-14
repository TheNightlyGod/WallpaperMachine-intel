use objc2::rc::Retained;
use objc2_core_graphics::{CGColor, CGColorSpace, kCGColorSpaceSRGB};
use objc2_foundation::{NSPoint, NSRect, NSSize, NSThread};
use objc2_quartz_core::{CAAutoresizingMask, CAMetalLayer};

use crate::PlaceholderStyle;

pub mod callback;
pub mod state;
pub mod watcher;

const DEFAULT_REFRESH_RATE_HZ: u32 = 60;

/// Stable identity metadata for matching non-primary displays across sessions.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct DisplayIdentity {
    pub uuid: Option<String>,
    pub vendor_id: Option<u32>,
    pub model_id: Option<u32>,
    pub serial_number: Option<u32>,
    pub unit_number: Option<u32>,
    pub name: Option<String>,
}

impl DisplayIdentity {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.uuid.is_none()
            && self.vendor_id.is_none()
            && self.model_id.is_none()
            && self.serial_number.is_none()
            && self.unit_number.is_none()
            && self.name.is_none()
    }

    /// Returns a debug-friendly label describing the identifying fields present
    /// on this identity.
    #[must_use]
    pub fn identity_label(&self) -> String {
        let mut parts = Vec::new();
        if let Some(value) = self.uuid.as_deref() {
            parts.push(format!("uuid={value}"));
        }
        if let Some(value) = self.vendor_id {
            parts.push(format!("vendor={value}"));
        }
        if let Some(value) = self.model_id {
            parts.push(format!("model={value}"));
        }
        if let Some(value) = self.serial_number {
            parts.push(format!("serial={value}"));
        }
        if let Some(value) = self.unit_number {
            parts.push(format!("unit={value}"));
        }
        if let Some(value) = self.name.as_deref() {
            parts.push(format!("name={value}"));
        }
        if parts.is_empty() {
            "none".to_string()
        } else {
            parts.join(",")
        }
    }

    /// How strongly `self` names the same physical display as `other`, or
    /// `None` when it names a different one: 4 for the UUID, 3 for vendor,
    /// model and serial, 2 for vendor, model and unit number.
    ///
    /// A key both sides carry decides on its own instead of falling through
    /// to a weaker one. macOS renumbers displays across reboots and
    /// reconnects, so two monitors of the same model regularly trade unit
    /// numbers; a unit match must never pair displays whose UUIDs or serials
    /// say they differ.
    #[must_use]
    pub fn match_score(&self, other: &Self) -> Option<u8> {
        if let (Some(left), Some(right)) = (
            self.uuid.as_deref().filter(|uuid| !uuid.is_empty()),
            other.uuid.as_deref().filter(|uuid| !uuid.is_empty()),
        ) {
            return (left == right).then_some(4);
        }
        if self.vendor_id.is_none()
            || self.model_id.is_none()
            || self.vendor_id != other.vendor_id
            || self.model_id != other.model_id
        {
            return None;
        }
        if let (Some(left), Some(right)) = (self.serial_number, other.serial_number) {
            return (left == right).then_some(3);
        }
        (self.unit_number.is_some() && self.unit_number == other.unit_number).then_some(2)
    }

    /// Whether both identities name the same display by a key that survives
    /// reconnects: the UUID, or vendor, model and serial. Unit numbers alone
    /// do not qualify.
    #[must_use]
    pub fn has_stable_match(&self, other: &Self) -> bool {
        self.match_score(other).is_some_and(|score| score >= 3)
    }
}

/// Pixel-space geometry and scale for a display target.
///
/// `x` and `y` are display origins in the macOS global point coordinate space.
/// `width` and `height` are physical pixel dimensions because the renderer
/// allocates swapchains/textures in pixels rather than logical display points.
#[derive(Clone, Debug, PartialEq)]
pub struct DisplayDesc {
    /// Platform display identifier. On macOS this is a `CGDirectDisplayID`.
    pub display_id: u32,
    /// Stable identity metadata for matching displays across sessions.
    pub identity: DisplayIdentity,
    /// Display origin on the global desktop x axis.
    pub x: i32,
    /// Display origin on the global desktop y axis.
    pub y: i32,
    /// Display width in physical pixels.
    pub width: u32,
    /// Display height in physical pixels.
    pub height: u32,
    /// Ratio between physical pixels and logical display points.
    pub scale_factor: f64,
    /// Current display refresh rate rounded to hertz.
    pub refresh_rate_hz: u32,
}

impl DisplayDesc {
    /// Constructs a display descriptor from already-normalized geometry.
    #[must_use]
    pub fn new(
        display_id: u32,
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        scale_factor: f64,
    ) -> Self {
        Self::with_identity(
            display_id,
            DisplayIdentity::default(),
            x,
            y,
            width,
            height,
            scale_factor,
        )
    }

    #[must_use]
    pub fn with_identity(
        display_id: u32,
        identity: DisplayIdentity,
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        scale_factor: f64,
    ) -> Self {
        Self {
            display_id,
            identity,
            x,
            y,
            width,
            height,
            scale_factor,
            refresh_rate_hz: DEFAULT_REFRESH_RATE_HZ,
        }
    }

    #[must_use]
    pub fn with_refresh_rate(mut self, refresh_rate_hz: u32) -> Self {
        self.refresh_rate_hz = refresh_rate_hz.max(1);
        self
    }

    /// Returns the main macOS display.
    ///
    /// # Errors
    ///
    /// Returns [`crate::EngineError::Platform`] if Core Graphics cannot
    /// enumerate active displays or reports no usable display.
    pub fn primary() -> Result<Self, crate::EngineError> {
        let mut metrics = sys::active_display_metrics()?;
        if let Some(index) = metrics.iter().position(|metrics| metrics.is_primary) {
            return Ok(DisplayDesc::from(metrics.swap_remove(index)));
        }
        metrics
            .into_iter()
            .next()
            .map(DisplayDesc::from)
            .ok_or_else(|| {
                crate::EngineError::Platform("no active displays were found".to_string())
            })
    }

    /// Returns a debug-friendly label describing this display's geometry and
    /// identity.
    #[must_use]
    pub fn desc_label(&self) -> String {
        let scale_factor = self.scale_factor.max(f64::MIN_POSITIVE);
        format!(
            "id={} origin=({}, {}) physical={}x{} scale={:.3} logical={:.2}x{:.2} refresh={}Hz \
             identity={}",
            self.display_id,
            self.x,
            self.y,
            self.width,
            self.height,
            self.scale_factor,
            f64::from(self.width) / scale_factor,
            f64::from(self.height) / scale_factor,
            self.refresh_rate_hz,
            self.identity.identity_label(),
        )
    }

    #[must_use]
    pub fn is_same_physical_display_as(&self, other: &DisplayDesc) -> bool {
        self.display_id == other.display_id || self.identity.match_score(&other.identity).is_some()
    }

    /// Whether the display reports a pixel size a window and a renderer
    /// surface can be built for.
    ///
    /// A display that is still connecting can be listed as active while its
    /// mode reports 0x0 pixels. Opening a window for it fails with
    /// [`crate::EngineError::InvalidInput`].
    #[must_use]
    pub fn has_presentable_size(&self) -> bool {
        self.width > 0 && self.height > 0
    }

    /// Builds a `CAMetalLayer` matching this display's geometry and the
    /// provided placeholder style.
    ///
    /// Must be called on the main thread. Does NOT attach the layer to any
    /// view.
    #[must_use]
    pub fn build_metal_layer(&self, style: &PlaceholderStyle) -> Retained<CAMetalLayer> {
        debug_assert!(NSThread::isMainThread_class());

        let scale_factor = if self.scale_factor > 0.0 {
            self.scale_factor
        } else {
            1.0
        };
        let point_width = f64::from(self.width) / scale_factor;
        let point_height = f64::from(self.height) / scale_factor;
        let content_frame = NSRect::new(NSPoint::ZERO, NSSize::new(point_width, point_height));
        let drawable_size = NSSize::new(f64::from(self.width), f64::from(self.height));

        let metal_layer = CAMetalLayer::layer();
        let layer_color = CGColor::new_generic_rgb(style.red, style.green, style.blue, style.alpha);

        metal_layer.setFrame(content_frame);
        metal_layer.setAutoresizingMask(
            CAAutoresizingMask::LayerWidthSizable | CAAutoresizingMask::LayerHeightSizable,
        );
        metal_layer.setContentsScale(scale_factor);
        metal_layer.setDrawableSize(drawable_size);
        // Match the sRGB native desktop poster instead of interpreting the
        // same final pixels in the display's (possibly wide-gamut) color space.
        if let Some(color_space) = CGColorSpace::with_name(Some(unsafe { kCGColorSpaceSRGB })) {
            metal_layer.setColorspace(Some(&color_space));
        }
        metal_layer.setBackgroundColor(Some(&layer_color));

        metal_layer
    }

    /// Returns true iff the geometry fields (id, origin, size, `scale_factor`)
    /// match `other`. `identity` is intentionally excluded — this is used
    /// for detecting geometry changes in the display-change event stream,
    /// where identity changes are surfaced as a separate event.
    #[must_use]
    pub fn has_same_geometry(&self, other: &DisplayDesc) -> bool {
        self.display_id == other.display_id
            && self.x == other.x
            && self.y == other.y
            && self.width == other.width
            && self.height == other.height
            && (self.scale_factor - other.scale_factor).abs() <= f64::EPSILON
    }

    /// Returns true iff fields that determine renderer surface allocation
    /// match.
    ///
    /// Window origin and display id can change independently from pixel size
    /// and scale during desktop topology churn. Those cases should move the
    /// window without forcing a renderer surface reconfigure.
    #[must_use]
    pub fn has_same_render_surface(&self, other: &DisplayDesc) -> bool {
        self.width == other.width
            && self.height == other.height
            && (self.scale_factor - other.scale_factor).abs() <= f64::EPSILON
    }

    /// Returns all active macOS displays.
    ///
    /// # Errors
    ///
    /// Returns [`crate::EngineError::Platform`] if Core Graphics cannot
    /// enumerate active displays or if display geometry overflows
    /// wallpaper-core's numeric representation.
    pub fn all() -> Result<Vec<Self>, crate::EngineError> {
        sys::active_display_metrics().map(|metrics| {
            metrics
                .into_iter()
                .map(DisplayDesc::from)
                .collect::<Vec<_>>()
        })
    }
}

/// What one display report from the platform means for the running scenes.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum RefreshPlan {
    /// The primary display has no pixels, so the whole layout is in flux and
    /// every runtime stays as it is until the next report.
    Skip { reason: String },
    /// The report is usable. `transitional` holds the displays that report no
    /// pixels yet: they stay out of `displays`, and a display that already
    /// runs a scene keeps the descriptor it had.
    Apply {
        primary: DisplayDesc,
        displays: Vec<DisplayDesc>,
        transitional: Vec<DisplayDesc>,
    },
}

/// Splits a platform display report into the displays a scene can be placed
/// on and the ones that are still connecting.
///
/// The platform watcher schedules another refresh on every display
/// reconfiguration, so a display left out here is picked up when it settles.
#[must_use]
pub(crate) fn plan_refresh(primary: DisplayDesc, all: Vec<DisplayDesc>) -> RefreshPlan {
    if !primary.has_presentable_size() {
        return RefreshPlan::Skip {
            reason: format!(
                "primary display {} reports {}x{} px",
                primary.display_id, primary.width, primary.height
            ),
        };
    }
    let (displays, transitional) = all
        .into_iter()
        .partition(DisplayDesc::has_presentable_size);
    RefreshPlan::Apply {
        primary,
        displays,
        transitional,
    }
}

/// Remembers which display-report problems were already logged, so a refresh
/// that repeats the same one on every reconfiguration event stays quiet.
#[derive(Debug, Default)]
pub(crate) struct RefreshReportLog {
    last_skip_reason: Option<String>,
    reported_transitional: Vec<u32>,
}

impl RefreshReportLog {
    /// The line to log for `plan`, or `None` when this situation was already
    /// logged and has not changed since.
    pub(crate) fn message_for(&mut self, plan: &RefreshPlan) -> Option<String> {
        match plan {
            RefreshPlan::Skip { reason } => {
                if self.last_skip_reason.as_deref() == Some(reason.as_str()) {
                    return None;
                }
                self.last_skip_reason = Some(reason.clone());
                Some(format!(
                    "[wallpaper-core display] keeping every scene as it is: {reason}"
                ))
            }
            RefreshPlan::Apply { transitional, .. } => {
                self.last_skip_reason = None;
                let mut sorted: Vec<&DisplayDesc> = transitional.iter().collect();
                sorted.sort_by_key(|display| display.display_id);
                let ids: Vec<u32> = sorted.iter().map(|display| display.display_id).collect();
                if ids == self.reported_transitional {
                    return None;
                }
                self.reported_transitional.clone_from(&ids);
                if ids.is_empty() {
                    return None;
                }
                let labels = sorted
                    .into_iter()
                    .map(|display| {
                        format!(
                            "display {} ({}x{} px)",
                            display.display_id, display.width, display.height
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(", ");
                Some(format!(
                    "[wallpaper-core display] ignoring {labels} until it reports a size"
                ))
            }
        }
    }
}

impl From<DisplayMetrics> for DisplayDesc {
    #[allow(clippy::cast_possible_truncation)]
    fn from(metrics: DisplayMetrics) -> Self {
        let scale_factor = [
            (f64::from(metrics.pixel_width), metrics.logical_width),
            (f64::from(metrics.pixel_height), metrics.logical_height),
        ]
        .into_iter()
        .find_map(|(pixels, points)| {
            if points > 0.0 {
                let computed = pixels / points;
                if computed.is_finite() && computed >= 1.0 {
                    return Some(computed);
                }
            }
            None
        })
        .unwrap_or(1.0);

        let appkit_origin_y = if metrics.primary_logical_height.is_finite()
            && metrics.primary_logical_height > 0.0
            && metrics.logical_height.is_finite()
            && metrics.logical_height > 0.0
        {
            metrics.primary_logical_height - metrics.origin_y - metrics.logical_height
        } else {
            metrics.origin_y
        };

        DisplayDesc::with_identity(
            metrics.display_id,
            metrics.identity,
            metrics.origin_x.round() as i32,
            appkit_origin_y.round() as i32,
            metrics.pixel_width,
            metrics.pixel_height,
            scale_factor,
        )
        .with_refresh_rate(metrics.refresh_rate_hz)
    }
}

#[derive(Clone, Debug, PartialEq)]
struct DisplayMetrics {
    display_id: u32,
    identity: DisplayIdentity,
    origin_x: f64,
    origin_y: f64,
    logical_width: f64,
    logical_height: f64,
    pixel_width: u32,
    pixel_height: u32,
    primary_logical_height: f64,
    refresh_rate_hz: u32,
    is_primary: bool,
}

mod sys {
    use objc2_core_foundation::{CFRetained, CFUUID};
    use objc2_core_graphics::{
        CGDirectDisplayID, CGDisplayBounds, CGDisplayCopyDisplayMode, CGDisplayMode,
        CGDisplayModelNumber, CGDisplayPixelsHigh, CGDisplayPixelsWide, CGDisplaySerialNumber,
        CGDisplayUnitNumber, CGDisplayVendorNumber, CGError, CGGetActiveDisplayList,
        CGMainDisplayID,
    };

    use super::{DEFAULT_REFRESH_RATE_HZ, DisplayMetrics};

    fn non_zero(value: u32) -> Option<u32> {
        if value == 0 { None } else { Some(value) }
    }

    unsafe extern "C-unwind" {
        fn CGDisplayCreateUUIDFromDisplayID(
            display: CGDirectDisplayID,
        ) -> Option<CFRetained<CFUUID>>;
    }

    pub fn active_display_metrics() -> Result<Vec<DisplayMetrics>, crate::EngineError> {
        let mut display_count = 0;
        let error =
            unsafe { CGGetActiveDisplayList(0, std::ptr::null_mut(), &raw mut display_count) };
        if error != CGError::Success {
            return Err(platform_error(format!(
                "CGGetActiveDisplayList failed while counting displays: {error:?}"
            )));
        }

        if display_count == 0 {
            return Ok(Vec::new());
        }

        let mut display_ids = vec![0; display_count as usize];
        let error = unsafe {
            CGGetActiveDisplayList(
                display_count,
                display_ids.as_mut_ptr(),
                &raw mut display_count,
            )
        };
        if error != CGError::Success {
            return Err(platform_error(format!(
                "CGGetActiveDisplayList failed while reading displays: {error:?}"
            )));
        }

        display_ids.truncate(display_count as usize);
        let main_display_id = CGMainDisplayID();
        let primary_logical_height = {
            let reference_display_id = if main_display_id == 0 {
                display_ids[0]
            } else {
                main_display_id
            };
            CGDisplayBounds(reference_display_id).size.height
        };

        display_ids
            .into_iter()
            .enumerate()
            .map(|(index, display_id)| {
                display_metrics(
                    display_id,
                    &format!("display {index}"),
                    primary_logical_height,
                    if main_display_id == 0 {
                        index == 0
                    } else {
                        display_id == main_display_id
                    },
                )
            })
            .collect()
    }

    #[allow(
        clippy::cast_possible_truncation,
        clippy::cast_precision_loss,
        clippy::cast_sign_loss,
        clippy::single_call_fn
    )]
    fn display_metrics(
        display_id: CGDirectDisplayID,
        label: &str,
        primary_logical_height: f64,
        is_primary: bool,
    ) -> Result<DisplayMetrics, crate::EngineError> {
        if display_id == 0 {
            return Err(platform_error(format!("{label} id was 0")));
        }

        let bounds = CGDisplayBounds(display_id);
        let (logical_width, logical_height, pixel_width, pixel_height, refresh_rate_hz) =
            if let Some(mode) = CGDisplayCopyDisplayMode(display_id) {
                let logical_width = CGDisplayMode::width(Some(&mode)) as f64;
                let logical_height = CGDisplayMode::height(Some(&mode)) as f64;
                let pixel_width = u32::try_from(CGDisplayMode::pixel_width(Some(&mode)))
                    .map_err(|_| platform_error(format!("{label} pixel width overflowed u32")))?;
                let pixel_height = u32::try_from(CGDisplayMode::pixel_height(Some(&mode)))
                    .map_err(|_| platform_error(format!("{label} pixel height overflowed u32")))?;
                let refresh_rate = CGDisplayMode::refresh_rate(Some(&mode));
                let refresh_rate_hz = if refresh_rate.is_finite() && refresh_rate > 0.0 {
                    refresh_rate.round().clamp(1.0, f64::from(u32::MAX)) as u32
                } else {
                    DEFAULT_REFRESH_RATE_HZ
                };
                (
                    logical_width,
                    logical_height,
                    pixel_width,
                    pixel_height,
                    refresh_rate_hz,
                )
            } else {
                let pixel_width = u32::try_from(CGDisplayPixelsWide(display_id))
                    .map_err(|_| platform_error(format!("{label} width overflowed u32")))?;
                let pixel_height = u32::try_from(CGDisplayPixelsHigh(display_id))
                    .map_err(|_| platform_error(format!("{label} height overflowed u32")))?;
                (
                    bounds.size.width,
                    bounds.size.height,
                    pixel_width,
                    pixel_height,
                    DEFAULT_REFRESH_RATE_HZ,
                )
            };

        Ok(DisplayMetrics {
            display_id,
            identity: super::DisplayIdentity::from(display_id),
            origin_x: bounds.origin.x,
            origin_y: bounds.origin.y,
            logical_width,
            logical_height,
            pixel_width,
            pixel_height,
            primary_logical_height,
            refresh_rate_hz,
            is_primary,
        })
    }

    impl From<CGDirectDisplayID> for super::DisplayIdentity {
        fn from(display_id: CGDirectDisplayID) -> Self {
            let uuid = unsafe { CGDisplayCreateUUIDFromDisplayID(display_id) }
                .and_then(|uuid| CFUUID::new_string(None, Some(&uuid)))
                .map(|value| value.to_string());

            Self {
                uuid,
                vendor_id: non_zero(CGDisplayVendorNumber(display_id)),
                model_id: non_zero(CGDisplayModelNumber(display_id)),
                serial_number: non_zero(CGDisplaySerialNumber(display_id)),
                unit_number: non_zero(CGDisplayUnitNumber(display_id)),
                name: None,
            }
        }
    }

    fn platform_error(message: impl Into<String>) -> crate::EngineError {
        crate::EngineError::Platform(message.into())
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DisplayDesc, DisplayIdentity, DisplayMetrics, RefreshPlan, RefreshReportLog, plan_refresh,
    };

    fn assert_f64_close(actual: f64, expected: f64) {
        assert!(
            (actual - expected).abs() <= f64::EPSILON,
            "expected {actual} to be within f64::EPSILON of {expected}"
        );
    }

    #[test]
    fn display_descriptor_keeps_geometry() {
        let display = DisplayDesc::new(42, -1920, 0, 1920, 1080, 2.0);

        assert_eq!(display.display_id, 42);
        assert!(display.identity.is_empty());
        assert_eq!(display.x, -1920);
        assert_eq!(display.y, 0);
        assert_eq!(display.width, 1920);
        assert_eq!(display.height, 1080);
        assert_f64_close(display.scale_factor, 2.0);
        assert_eq!(display.refresh_rate_hz, 60);
    }

    #[test]
    fn metrics_to_display_desc_derives_scale_factor_from_bounds() {
        let display = DisplayDesc::from(DisplayMetrics {
            display_id: 7,
            identity: DisplayIdentity {
                uuid: Some("test-display".to_string()),
                ..DisplayIdentity::default()
            },
            origin_x: -1280.0,
            origin_y: 0.0,
            logical_width: 1280.0,
            logical_height: 720.0,
            pixel_width: 2560,
            pixel_height: 1440,
            primary_logical_height: 720.0,
            refresh_rate_hz: 75,
            is_primary: false,
        });

        assert_eq!(display.display_id, 7);
        assert_eq!(display.identity.uuid.as_deref(), Some("test-display"));
        assert_eq!(display.x, -1280);
        assert_eq!(display.y, 0);
        assert_eq!(display.width, 2560);
        assert_eq!(display.height, 1440);
        assert_f64_close(display.scale_factor, 2.0);
        assert_eq!(display.refresh_rate_hz, 75);
    }

    #[test]
    fn metrics_to_display_desc_converts_quartz_y_to_appkit_y() {
        let shorter_secondary = DisplayDesc::from(DisplayMetrics {
            display_id: 2,
            identity: DisplayIdentity::default(),
            origin_x: 1710.0,
            origin_y: 0.0,
            logical_width: 1920.0,
            logical_height: 1080.0,
            pixel_width: 1920,
            pixel_height: 1080,
            primary_logical_height: 1107.0,
            refresh_rate_hz: 60,
            is_primary: false,
        });
        let taller_secondary = DisplayDesc::from(DisplayMetrics {
            display_id: 3,
            identity: DisplayIdentity::default(),
            origin_x: 1920.0,
            origin_y: 0.0,
            logical_width: 1710.0,
            logical_height: 1107.0,
            pixel_width: 3420,
            pixel_height: 2214,
            primary_logical_height: 1080.0,
            refresh_rate_hz: 60,
            is_primary: false,
        });

        assert_eq!(shorter_secondary.y, 27);
        assert_eq!(taller_secondary.y, -27);
    }

    #[test]
    fn metrics_to_display_desc_falls_back_to_unit_scale_when_bounds_are_invalid() {
        let display = DisplayDesc::from(DisplayMetrics {
            display_id: 1,
            identity: DisplayIdentity::default(),
            origin_x: 0.0,
            origin_y: 0.0,
            logical_width: 0.0,
            logical_height: 0.0,
            pixel_width: 1920,
            pixel_height: 1080,
            primary_logical_height: 0.0,
            refresh_rate_hz: 60,
            is_primary: false,
        });

        assert_f64_close(display.scale_factor, 1.0);
    }

    #[test]
    fn display_identity_scores_uuid_first() {
        let left = DisplayIdentity {
            uuid: Some("A".to_string()),
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: Some(3),
            unit_number: Some(4),
            name: None,
        };
        let right = DisplayIdentity {
            uuid: Some("A".to_string()),
            vendor_id: Some(9),
            model_id: Some(9),
            serial_number: Some(9),
            unit_number: Some(9),
            name: None,
        };

        assert_eq!(left.match_score(&right), Some(4));
    }

    #[test]
    fn display_identity_scores_vendor_model_serial() {
        let left = DisplayIdentity {
            uuid: None,
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: Some(3),
            unit_number: Some(7),
            name: None,
        };
        let right = DisplayIdentity {
            uuid: None,
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: Some(3),
            unit_number: Some(8),
            name: None,
        };

        assert_eq!(left.match_score(&right), Some(3));
    }

    #[test]
    fn display_identity_scores_vendor_model_unit() {
        let left = DisplayIdentity {
            uuid: None,
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: None,
            unit_number: Some(7),
            name: None,
        };
        let right = DisplayIdentity {
            uuid: None,
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: None,
            unit_number: Some(7),
            name: None,
        };

        assert_eq!(left.match_score(&right), Some(2));
    }

    #[test]
    fn display_identity_scores_no_match() {
        let left = DisplayIdentity {
            uuid: None,
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: Some(3),
            unit_number: Some(7),
            name: None,
        };
        let right = DisplayIdentity {
            uuid: None,
            vendor_id: Some(1),
            model_id: Some(9),
            serial_number: Some(3),
            unit_number: Some(7),
            name: None,
        };

        assert_eq!(left.match_score(&right), None);
    }

    /// Two monitors of the same model trade unit numbers when macOS
    /// renumbers displays; their UUIDs and serials still tell them apart.
    #[test]
    fn identical_models_sharing_a_unit_number_do_not_match() {
        let left = DisplayIdentity {
            uuid: Some("LEFT".to_string()),
            vendor_id: Some(16652),
            model_id: Some(50182),
            serial_number: Some(1),
            unit_number: Some(3),
            name: Some("27M2N3200NF (1)".to_string()),
        };
        let right = DisplayIdentity {
            uuid: Some("RIGHT".to_string()),
            serial_number: Some(2),
            name: Some("27M2N3200NF (2)".to_string()),
            ..left.clone()
        };
        let without_uuids = |identity: &DisplayIdentity| DisplayIdentity {
            uuid: None,
            ..identity.clone()
        };
        let without_serials = |identity: &DisplayIdentity| DisplayIdentity {
            serial_number: None,
            ..identity.clone()
        };

        assert_eq!(left.match_score(&right), None);
        assert_eq!(
            without_uuids(&left).match_score(&without_uuids(&right)),
            None
        );
        assert_eq!(
            without_serials(&left).match_score(&without_serials(&right)),
            None
        );
        assert!(
            !DisplayDesc::with_identity(4, left.clone(), 0, 0, 3840, 2160, 2.0)
                .is_same_physical_display_as(&DisplayDesc::with_identity(
                    5, right, 0, 0, 3840, 2160, 2.0
                ))
        );

        let renumbered = DisplayIdentity {
            unit_number: Some(4),
            name: Some("27M2N3200NF (2)".to_string()),
            ..left.clone()
        };
        assert_eq!(left.match_score(&renumbered), Some(4));
        assert!(left.has_stable_match(&renumbered));
        assert_eq!(
            without_uuids(&left).match_score(&without_uuids(&renumbered)),
            Some(3)
        );
    }

    #[test]
    fn a_unit_number_match_is_not_stable() {
        let left = DisplayIdentity {
            uuid: None,
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: None,
            unit_number: Some(7),
            name: None,
        };

        assert_eq!(left.match_score(&left), Some(2));
        assert!(!left.has_stable_match(&left));
    }

    #[test]
    fn metrics_to_display_desc_keeps_identity() {
        let identity = DisplayIdentity {
            uuid: Some("display-uuid".to_string()),
            vendor_id: Some(10),
            model_id: Some(20),
            serial_number: Some(30),
            unit_number: Some(40),
            name: None,
        };
        let display = DisplayDesc::from(DisplayMetrics {
            display_id: 7,
            identity: identity.clone(),
            origin_x: 0.0,
            origin_y: 0.0,
            logical_width: 1920.0,
            logical_height: 1080.0,
            pixel_width: 3840,
            pixel_height: 2160,
            primary_logical_height: 1080.0,
            refresh_rate_hz: 120,
            is_primary: false,
        });

        assert_eq!(display.identity, identity);
        assert_f64_close(display.scale_factor, 2.0);
        assert_eq!(display.refresh_rate_hz, 120);
    }

    fn apply_parts(plan: RefreshPlan) -> (DisplayDesc, Vec<u32>, Vec<u32>) {
        match plan {
            RefreshPlan::Apply {
                primary,
                displays,
                transitional,
            } => (
                primary,
                displays.iter().map(|display| display.display_id).collect(),
                transitional
                    .iter()
                    .map(|display| display.display_id)
                    .collect(),
            ),
            RefreshPlan::Skip { reason } => {
                panic!("expected an applicable plan, got skip: {reason}")
            }
        }
    }

    #[test]
    fn plan_refresh_splits_zero_width_and_zero_height_displays() {
        let primary = DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0);
        let all = vec![
            primary.clone(),
            DisplayDesc::new(2, 1920, 0, 0, 1080, 1.0),
            DisplayDesc::new(3, 3840, 0, 1920, 0, 1.0),
            DisplayDesc::new(4, 5760, 0, 1, 1, 1.0),
        ];

        let (kept_primary, displays, transitional) =
            apply_parts(plan_refresh(primary.clone(), all));

        assert_eq!(kept_primary, primary);
        assert_eq!(displays, vec![1, 4]);
        assert_eq!(transitional, vec![2, 3]);
    }

    #[test]
    fn plan_refresh_still_applies_the_primary_when_every_other_display_is_degenerate() {
        let primary = DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0);
        let all = vec![
            primary.clone(),
            DisplayDesc::new(2, 1920, 0, 0, 0, 1.0),
            DisplayDesc::new(3, 3840, 0, 0, 0, 1.0),
        ];

        let (_, displays, transitional) = apply_parts(plan_refresh(primary, all));

        assert_eq!(displays, vec![1]);
        assert_eq!(transitional, vec![2, 3]);
    }

    #[test]
    fn plan_refresh_skips_when_the_primary_has_no_pixels() {
        let primary = DisplayDesc::new(9, 0, 0, 0, 0, 1.0);
        let all = vec![primary.clone(), DisplayDesc::new(2, 1920, 0, 1920, 1080, 1.0)];

        match plan_refresh(primary, all) {
            RefreshPlan::Skip { reason } => {
                assert!(reason.contains('9'), "reason should name display 9: {reason}");
            }
            RefreshPlan::Apply { .. } => panic!("a primary without pixels must skip the refresh"),
        }
    }

    #[test]
    fn report_log_mentions_a_transitional_display_once_until_the_set_changes() {
        let primary = DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0);
        let plan = |ids: &[u32]| {
            let mut all = vec![primary.clone()];
            all.extend(ids.iter().map(|id| DisplayDesc::new(*id, 0, 0, 0, 0, 1.0)));
            plan_refresh(primary.clone(), all)
        };
        let mut log = RefreshReportLog::default();

        let first = log.message_for(&plan(&[5])).expect("first report is logged");
        assert!(first.contains('5'), "{first}");
        assert_eq!(log.message_for(&plan(&[5])), None);

        let wider = log.message_for(&plan(&[7, 5])).expect("a changed set is logged");
        assert!(wider.contains('5') && wider.contains('7'), "{wider}");

        assert_eq!(log.message_for(&plan(&[])), None, "settling is not a problem to log");
        assert!(
            log.message_for(&plan(&[5])).is_some(),
            "the same display going degenerate again is a new event"
        );
    }

    #[test]
    fn report_log_mentions_a_skipped_refresh_once_per_reason() {
        let skip = |id: u32| {
            plan_refresh(
                DisplayDesc::new(id, 0, 0, 0, 0, 1.0),
                vec![DisplayDesc::new(id, 0, 0, 0, 0, 1.0)],
            )
        };
        let healthy = plan_refresh(
            DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0),
            vec![DisplayDesc::new(1, 0, 0, 1920, 1080, 1.0)],
        );
        let mut log = RefreshReportLog::default();

        assert!(log.message_for(&skip(1)).is_some());
        assert_eq!(log.message_for(&skip(1)), None);
        assert!(log.message_for(&skip(2)).is_some(), "another display is another reason");

        assert_eq!(log.message_for(&healthy), None);
        assert!(
            log.message_for(&skip(2)).is_some(),
            "a refresh that applied in between makes the next skip new again"
        );
    }
}
