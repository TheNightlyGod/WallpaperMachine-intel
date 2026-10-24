// Clean-room implementation from the WallpaperMachine spec r1b-core-display.md; written without access to the original source.
use objc2::{MainThreadMarker, rc::Retained};
use objc2_core_foundation::{CFRetained, CFString, CFUUID, CGPoint, CGRect, CGSize};
use objc2_core_graphics::{CGColor, CGColorSpace, CGDisplayMode, CGError, kCGColorSpaceSRGB};
use objc2_quartz_core::{CAAutoresizingMask, CALayer, CAMetalLayer};

use crate::PlaceholderStyle;

pub mod callback;
pub mod state;
pub mod watcher;

/// Names a display independently of its numeric id, which the system may hand
/// out again after a reconnect. A uuid, or vendor + model + serial, is stable.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct DisplayIdentity {
    /// The persistent identifier the system assigns to the attached panel.
    /// It survives reconnects and renumbering, so it is the best key when
    /// the system reports one.
    pub uuid: Option<String>,
    /// Vendor code of the panel.
    /// Together with the model and a serial or unit number this names a
    /// display when no uuid is available.
    pub vendor_id: Option<u32>,
    /// Model code of the panel.
    /// Identical models share it, so it never identifies a display alone.
    /// It is compared together with the vendor.
    pub model_id: Option<u32>,
    /// Serial number the panel reports.
    /// With the vendor and model it names one physical panel.
    /// The unit number can stand in for it.
    pub serial_number: Option<u32>,
    /// Unit number the system reports for the panel.
    /// With the vendor and model it can tell two identical monitors apart.
    /// It is the alternative to the serial number.
    pub unit_number: Option<u32>,
    /// Human-readable name, for labels only.
    /// It is not part of what identifies a display.
    /// Two different displays may have the same name.
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

    #[must_use]
    pub fn identity_label(&self) -> String {
        let named = [
            ("uuid", self.uuid.clone()),
            ("vendor", self.vendor_id.map(|value| value.to_string())),
            ("model", self.model_id.map(|value| value.to_string())),
            ("serial", self.serial_number.map(|value| value.to_string())),
            ("unit", self.unit_number.map(|value| value.to_string())),
            ("name", self.name.clone()),
        ];
        let present: Vec<String> = named
            .into_iter()
            .filter_map(|(field, value)| value.map(|value| format!("{field}: {value}")))
            .collect();
        match present.as_slice() {
            [] => "no identity fields".to_owned(),
            fields => format!("[{}]", fields.join("; ")),
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

/// Geometry, scale and identity of one display. See the display spec for the
/// meaning of each field.
#[derive(Clone, Debug, PartialEq)]
pub struct DisplayDesc {
    pub display_id: u32,
    pub identity: DisplayIdentity,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scale_factor: f64,
    pub refresh_rate_hz: u32,
}

impl DisplayDesc {
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
    pub fn with_refresh_rate(self, refresh_rate_hz: u32) -> Self {
        Self {
            refresh_rate_hz: refresh_rate_hz.max(1),
            ..self
        }
    }

    /// The display the system calls the main one.
    ///
    /// # Errors
    ///
    /// `Platform` when no display can be read.
    pub fn primary() -> Result<Self, crate::EngineError> {
        let mut metrics = platform::read_displays()?;
        let main = platform::main_display_index(&metrics).ok_or_else(|| {
            crate::EngineError::Platform("no active displays were found".to_string())
        })?;
        Ok(metrics.swap_remove(main).into())
    }

    #[must_use]
    pub fn desc_label(&self) -> String {
        // A scale of zero or less reads as the smallest positive number.
        let divisor = self.scale_factor.max(f64::MIN_POSITIVE);
        let points = (
            f64::from(self.width) / divisor,
            f64::from(self.height) / divisor,
        );
        format!(
            "display {id} at ({x}, {y}), {w}x{h} px, scale {scale:.3}, {pw:.1}x{ph:.1} pt, {hz} Hz, {identity}",
            id = self.display_id,
            x = self.x,
            y = self.y,
            w = self.width,
            h = self.height,
            scale = self.scale_factor,
            pw = points.0,
            ph = points.1,
            hz = self.refresh_rate_hz,
            identity = self.identity.identity_label(),
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

    #[must_use]
    pub fn build_metal_layer(&self, style: &PlaceholderStyle) -> Retained<CAMetalLayer> {
        debug_assert!(
            MainThreadMarker::new().is_some(),
            "Metal layers are built on the main thread"
        );
        let scale = sanitized_scale(self.scale_factor);
        let layer = CAMetalLayer::layer();
        layer.setFrame(CGRect::new(
            CGPoint::new(0.0, 0.0),
            CGSize::new(
                f64::from(self.width) / scale,
                f64::from(self.height) / scale,
            ),
        ));
        layer.setAutoresizingMask(
            CAAutoresizingMask::LayerWidthSizable | CAAutoresizingMask::LayerHeightSizable,
        );
        layer.setContentsScale(scale);
        layer.setDrawableSize(CGSize::new(
            f64::from(self.width),
            f64::from(self.height),
        ));
        // SAFETY: the constant is a valid colour space name owned by CoreGraphics.
        let srgb = CGColorSpace::with_name(Some(unsafe { kCGColorSpaceSRGB }));
        layer.setColorspace(srgb.as_deref());
        let background = CGColor::new_srgb(style.red, style.green, style.blue, style.alpha);
        CALayer::setBackgroundColor(&layer, Some(&background));
        layer
    }

    #[must_use]
    pub fn has_same_geometry(&self, other: &DisplayDesc) -> bool {
        self.display_id == other.display_id
            && self.x == other.x
            && self.y == other.y
            && self.has_same_render_surface(other)
    }

    #[must_use]
    pub fn has_same_render_surface(&self, other: &DisplayDesc) -> bool {
        self.width == other.width
            && self.height == other.height
            && (self.scale_factor - other.scale_factor).abs() <= f64::EPSILON
    }

    /// Every active display in system order.
    ///
    /// # Errors
    ///
    /// `Platform` when the display list cannot be read.
    pub fn all() -> Result<Vec<Self>, crate::EngineError> {
        Ok(platform::read_displays()?
            .into_iter()
            .map(Self::from)
            .collect())
    }
}

/// Refresh rate a descriptor reports when no mode says otherwise.
const DEFAULT_REFRESH_RATE_HZ: u32 = 60;

/// A scale of 0 or less, or one that is not a number, reads as 1.
pub(crate) fn sanitized_scale(scale: f64) -> f64 {
    if scale.is_finite() && scale > 0.0 {
        scale
    } else {
        1.0
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
    fn from(metrics: DisplayMetrics) -> Self {
        let ratio = |pixels: u32, logical: f64| {
            let ratio = f64::from(pixels) / logical;
            (logical > 0.0 && ratio.is_finite() && ratio >= 1.0).then_some(ratio)
        };
        let scale_factor = ratio(metrics.pixel_width, metrics.logical_width)
            .or_else(|| ratio(metrics.pixel_height, metrics.logical_height))
            .unwrap_or(1.0);
        let heights_usable = metrics.primary_logical_height.is_finite()
            && metrics.primary_logical_height > 0.0
            && metrics.logical_height.is_finite()
            && metrics.logical_height > 0.0;
        let appkit_y = if heights_usable {
            metrics.primary_logical_height - metrics.origin_y - metrics.logical_height
        } else {
            metrics.origin_y
        };
        // `as` saturates, which is the wanted behaviour for absurd origins.
        #[allow(clippy::cast_possible_truncation)]
        let (x, y) = (metrics.origin_x.round() as i32, appkit_y.round() as i32);
        DisplayDesc {
            display_id: metrics.display_id,
            identity: metrics.identity,
            x,
            y,
            width: metrics.pixel_width,
            height: metrics.pixel_height,
            scale_factor,
            refresh_rate_hz: metrics.refresh_rate_hz,
        }
    }
}

/// One display as the platform reports it, before conversion to a
/// [`DisplayDesc`]: origin and sizes in points (Quartz space), pixel size,
/// the primary display's point height and the mode's refresh rate.
#[derive(Clone, Debug, PartialEq)]
#[allow(dead_code)]
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

/// Reads the active display list from CoreGraphics. Everything here is
/// callable from any thread.
mod platform {
    use std::ptr;

    use super::{
        CFRetained, CFString, CFUUID, CGDisplayMode, CGError, DEFAULT_REFRESH_RATE_HZ,
        DisplayIdentity, DisplayMetrics,
    };
    use crate::EngineError;

    unsafe extern "C-unwind" {
        // Exported by the system frameworks the crate already links; the
        // returned UUID follows the Create rule.
        fn CGDisplayCreateUUIDFromDisplayID(display: u32) -> *const CFUUID;
    }

    /// Every active display, in system order. The list is empty when the
    /// system reports no active display.
    pub(super) fn read_displays() -> Result<Vec<DisplayMetrics>, EngineError> {
        let ids = active_display_ids()?;
        let main_id = objc2_core_graphics::CGMainDisplayID();
        let main_id = if main_id == 0 {
            ids.first().copied().unwrap_or(0)
        } else {
            main_id
        };
        let primary_logical_height = if main_id == 0 {
            0.0
        } else {
            logical_size(main_id).1
        };
        ids.iter()
            .enumerate()
            .map(|(position, id)| read_one(position, *id, main_id, primary_logical_height))
            .collect()
    }

    /// The index of the display the system calls main; the first listed one
    /// when the system names none.
    pub(super) fn main_display_index(displays: &[DisplayMetrics]) -> Option<usize> {
        if displays.is_empty() {
            return None;
        }
        let main_id = objc2_core_graphics::CGMainDisplayID();
        Some(
            displays
                .iter()
                .position(|display| main_id != 0 && display.display_id == main_id)
                .unwrap_or(0),
        )
    }

    fn active_display_ids() -> Result<Vec<u32>, EngineError> {
        let mut count = 0_u32;
        // SAFETY: a zero capacity with a null list only asks for the count.
        let status =
            unsafe { objc2_core_graphics::CGGetActiveDisplayList(0, ptr::null_mut(), &raw mut count) };
        if status != CGError::Success {
            return Err(EngineError::Platform(format!(
                "failed to count active displays: CoreGraphics error {}",
                status.0
            )));
        }
        let mut ids = vec![0_u32; count as usize];
        if count == 0 {
            return Ok(ids);
        }
        let mut written = 0_u32;
        // SAFETY: `ids` has room for `count` entries.
        let status = unsafe {
            objc2_core_graphics::CGGetActiveDisplayList(count, ids.as_mut_ptr(), &raw mut written)
        };
        if status != CGError::Success {
            return Err(EngineError::Platform(format!(
                "failed to list active displays: CoreGraphics error {}",
                status.0
            )));
        }
        ids.truncate(written as usize);
        if ids.contains(&0) {
            return Err(EngineError::Platform(
                "the active display list contains display id 0".to_string(),
            ));
        }
        Ok(ids)
    }

    /// Point size of a display: its mode's, or its bounds without a mode.
    fn logical_size(id: u32) -> (f64, f64) {
        let mode = objc2_core_graphics::CGDisplayCopyDisplayMode(id);
        if mode.is_some() {
            #[allow(clippy::cast_precision_loss)]
            return (
                CGDisplayMode::width(mode.as_deref()) as f64,
                CGDisplayMode::height(mode.as_deref()) as f64,
            );
        }
        let bounds = objc2_core_graphics::CGDisplayBounds(id);
        (bounds.size.width, bounds.size.height)
    }

    fn pixel_dimension(
        position: usize,
        what: &str,
        value: usize,
    ) -> Result<u32, EngineError> {
        u32::try_from(value).map_err(|_| {
            EngineError::Platform(format!(
                "display #{position} reports a {what} of {value} pixels, which does not fit 32 bits"
            ))
        })
    }

    fn read_one(
        position: usize,
        id: u32,
        main_id: u32,
        primary_logical_height: f64,
    ) -> Result<DisplayMetrics, EngineError> {
        let mode = objc2_core_graphics::CGDisplayCopyDisplayMode(id);
        let bounds = objc2_core_graphics::CGDisplayBounds(id);
        let (pixel_width, pixel_height, logical_width, logical_height, refresh) =
            if mode.is_some() {
                let mode = mode.as_deref();
                #[allow(clippy::cast_precision_loss)]
                (
                    CGDisplayMode::pixel_width(mode),
                    CGDisplayMode::pixel_height(mode),
                    CGDisplayMode::width(mode) as f64,
                    CGDisplayMode::height(mode) as f64,
                    CGDisplayMode::refresh_rate(mode),
                )
            } else {
                (
                    objc2_core_graphics::CGDisplayPixelsWide(id),
                    objc2_core_graphics::CGDisplayPixelsHigh(id),
                    bounds.size.width,
                    bounds.size.height,
                    0.0,
                )
            };
        Ok(DisplayMetrics {
            display_id: id,
            identity: identity_of(id),
            origin_x: bounds.origin.x,
            origin_y: bounds.origin.y,
            logical_width,
            logical_height,
            pixel_width: pixel_dimension(position, "width", pixel_width)?,
            pixel_height: pixel_dimension(position, "height", pixel_height)?,
            primary_logical_height,
            refresh_rate_hz: refresh_rate_to_hz(refresh),
            is_primary: id == main_id,
        })
    }

    pub(super) fn refresh_rate_to_hz(rate: f64) -> u32 {
        if rate.is_finite() && rate > 0.0 {
            // `as` saturates for absurd rates.
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            return (rate.round() as u32).max(1);
        }
        DEFAULT_REFRESH_RATE_HZ
    }

    fn identity_of(id: u32) -> DisplayIdentity {
        let known = |value: u32| (value != 0).then_some(value);
        DisplayIdentity {
            uuid: uuid_text(id),
            vendor_id: known(objc2_core_graphics::CGDisplayVendorNumber(id)),
            model_id: known(objc2_core_graphics::CGDisplayModelNumber(id)),
            serial_number: known(objc2_core_graphics::CGDisplaySerialNumber(id)),
            unit_number: known(objc2_core_graphics::CGDisplayUnitNumber(id)),
            name: None,
        }
    }

    /// The canonical 36-character UUID text of a display, if the system has one.
    fn uuid_text(id: u32) -> Option<String> {
        // SAFETY: plain call; a non-null result is owned by us (Create rule).
        let raw = unsafe { CGDisplayCreateUUIDFromDisplayID(id) };
        let uuid = ptr::NonNull::new(raw.cast_mut())?;
        // SAFETY: the pointer is a +1 CFUUID.
        let uuid: CFRetained<CFUUID> = unsafe { CFRetained::from_raw(uuid) };
        let text: CFRetained<CFString> = CFUUID::new_string(None, Some(&uuid))?;
        Some(text.to_string())
    }
}

#[cfg(test)]
mod descriptor_contract;

#[cfg(test)]
mod tests {
    use super::{
        DisplayDesc, DisplayIdentity, DisplayMetrics, RefreshPlan, RefreshReportLog, plan_refresh,
    };

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
    fn identity_that_only_has_a_name_is_not_empty() {
        let named = DisplayIdentity {
            name: Some("Studio".to_string()),
            ..DisplayIdentity::default()
        };
        assert!(DisplayIdentity::default().is_empty());
        assert!(!named.is_empty());
        let empty_uuid = DisplayIdentity {
            uuid: Some(String::new()),
            ..DisplayIdentity::default()
        };
        assert!(!empty_uuid.is_empty());
    }

    #[test]
    fn labels_name_every_present_field_in_order() {
        let identity = DisplayIdentity {
            uuid: Some("U".to_string()),
            vendor_id: Some(1),
            model_id: Some(2),
            serial_number: Some(3),
            unit_number: Some(4),
            name: Some("N".to_string()),
        };
        let identity_label = identity.identity_label();
        for part in ["uuid", "U", "vendor", "1", "model", "2", "serial", "3", "unit", "4", "name", "N"] {
            assert!(identity_label.contains(part), "{part} missing from {identity_label}");
        }
        let empty = DisplayIdentity::default().identity_label();
        assert!(empty.contains("no identity"), "{empty}");

        let label = DisplayDesc::with_identity(9, identity, -5, 7, 2880, 1800, 2.0)
            .with_refresh_rate(120)
            .desc_label();
        for part in ["display 9", "(-5, 7)", "2880x1800", "2.000", "1440.0x900.0", "120 Hz", "uuid"] {
            assert!(label.contains(part), "{part} missing from {label}");
        }
    }

    #[test]
    fn refresh_rate_is_clamped_and_geometry_compares_the_documented_fields() {
        let base = DisplayDesc::new(1, 0, 0, 100, 50, 2.0);
        assert_eq!(base.clone().with_refresh_rate(0).refresh_rate_hz, 1);
        assert_eq!(base.clone().with_refresh_rate(144).refresh_rate_hz, 144);

        let other_rate = base.clone().with_refresh_rate(120);
        assert!(base.has_same_geometry(&other_rate));
        assert!(!base.has_same_geometry(&DisplayDesc::new(2, 0, 0, 100, 50, 2.0)));
        assert!(!base.has_same_geometry(&DisplayDesc::new(1, 1, 0, 100, 50, 2.0)));
        let moved = DisplayDesc::new(1, 1, 0, 100, 50, 2.0);
        assert!(base.has_same_render_surface(&moved));
        assert!(!base.has_same_render_surface(&DisplayDesc::new(1, 0, 0, 100, 50, 1.0)));
        assert!(!base.has_same_render_surface(&DisplayDesc::new(1, 0, 0, 100, 51, 2.0)));
    }

    #[test]
    fn refresh_rates_round_clamp_and_default() {
        use super::platform::refresh_rate_to_hz;
        assert_eq!(refresh_rate_to_hz(59.94), 60);
        assert_eq!(refresh_rate_to_hz(120.0), 120);
        assert_eq!(refresh_rate_to_hz(0.2), 1);
        for unusable in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            assert_eq!(refresh_rate_to_hz(unusable), 60);
        }
    }

    fn metrics(
        pixels: (u32, u32),
        logical: (f64, f64),
        origin_y: f64,
        primary_height: f64,
    ) -> DisplayDesc {
        DisplayDesc::from(DisplayMetrics {
            display_id: 5,
            identity: DisplayIdentity::default(),
            origin_x: 0.4,
            origin_y,
            logical_width: logical.0,
            logical_height: logical.1,
            pixel_width: pixels.0,
            pixel_height: pixels.1,
            primary_logical_height: primary_height,
            refresh_rate_hz: 60,
            is_primary: false,
        })
    }

    #[test]
    fn metrics_scale_falls_back_to_the_height_and_y_to_quartz() {
        let by_height = metrics((1920, 1080), (0.0, 540.0), 0.0, 0.0);
        assert!((by_height.scale_factor - 2.0).abs() <= f64::EPSILON);
        let secondary = metrics((1280, 1024), (1280.0, 1024.0), 0.0, 900.0);
        assert_eq!(secondary.y, -124);
        let beside_taller = metrics((1280, 1024), (1280.0, 1024.0), 0.0, 1200.0);
        assert_eq!(beside_taller.y, 176);
        for bad in [0.0, f64::NAN] {
            assert_eq!(metrics((1280, 1024), (1280.0, 1024.0), 12.6, bad).y, 13);
        }
        assert_eq!(by_height.x, 0);
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
