use objc2::{
    ClassType, MainThreadMarker, MainThreadOnly, Message, define_class, msg_send, rc::Retained,
    runtime::AnyObject,
};
use objc2_app_kit::{
    NSApplication, NSBackingStoreType, NSColor, NSScreen, NSView, NSWindow,
    NSWindowAnimationBehavior, NSWindowCollectionBehavior, NSWindowStyleMask,
};
#[cfg(not(test))]
use objc2_app_kit::{NSEvent, NSEventMask, NSEventType};
use objc2_core_graphics::{CGWindowLevelForKey, CGWindowLevelKey};
use objc2_foundation::{
    NSDictionary, NSInteger, NSNotificationCenter, NSNumber, NSPoint, NSRect, NSSize, NSString,
    NSThread, ns_string,
};
use objc2_quartz_core::{CAMetalLayer, CATransaction};

use crate::{DisplayDesc, EngineError};

define_class!(
    // SAFETY: The subclass only overrides frame constraint behavior and does
    // not add ivars or custom memory management.
    #[unsafe(super = NSWindow)]
    #[thread_kind = MainThreadOnly]
    // Stable Objective-C identity used by Swift's native desktop-poster sync.
    #[name = "MWEWallpaperDesktopWindow"]
    struct WallpaperDesktopWindow;

    impl WallpaperDesktopWindow {
        #[unsafe(method(constrainFrameRect:toScreen:))]
        fn constrain_frame_rect_to_screen(
            &self,
            frame: NSRect,
            _screen: Option<&NSScreen>,
        ) -> NSRect {
            frame
        }
    }
);

impl WallpaperDesktopWindow {
    #[allow(clippy::single_call_fn)]
    unsafe fn init_with_content_rect(
        mtm: MainThreadMarker,
        frame: NSRect,
        style_mask: NSWindowStyleMask,
        backing: NSBackingStoreType,
        defer: bool,
    ) -> Retained<Self> {
        unsafe {
            msg_send![
                Self::alloc(mtm),
                initWithContentRect: frame,
                styleMask: style_mask,
                backing: backing,
                defer: defer
            ]
        }
    }
}

/// Background exposed before the first frame or while a drawable is unavailable.
/// Default to black so display wake and surface recreation cannot flash white.
#[derive(Clone, Copy, Debug)]
pub struct PlaceholderStyle {
    /// Red channel in the range AppKit accepts for sRGB colors.
    #[allow(clippy::doc_markdown)]
    pub red: f64,
    /// Green channel in the range AppKit accepts for sRGB colors.
    #[allow(clippy::doc_markdown)]
    pub green: f64,
    /// Blue channel in the range AppKit accepts for sRGB colors.
    #[allow(clippy::doc_markdown)]
    pub blue: f64,
    /// Alpha channel in the range AppKit accepts for sRGB colors.
    #[allow(clippy::doc_markdown)]
    pub alpha: f64,
}

impl Default for PlaceholderStyle {
    fn default() -> Self {
        Self {
            red: 0.0,
            green: 0.0,
            blue: 0.0,
            alpha: 1.0,
        }
    }
}

/// Name of the notification posted for every content layer a wallpaper window
/// gets, on the default `NSNotificationCenter` and synchronously on the main
/// thread, before the window is composited with it.
///
/// `object` is the new `CAMetalLayer`. `userInfo` holds `displayID`, an
/// `NSNumber` with the `CoreGraphics` display id, and `reason`, an `NSString`
/// with one of the [`LayerInstall`] strings. The host app matches the name and
/// the strings literally, so they change only together with its observer.
///
/// An observer runs inside the window operation that posts it, so it must be
/// cheap and must not call back into the bridge.
pub(crate) const LAYER_INSTALLED_NOTIFICATION: &str = "WallpaperMachine.wallpaperLayerInstalled";

/// Why a wallpaper window got a new content layer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LayerInstall {
    /// The window was just opened and is about to be ordered front.
    Open,
    /// A scene replacement installed a fresh layer for the new renderer.
    Replace,
    /// A display reconfigure installed a fresh layer for the new geometry.
    Reconfigure,
}

impl LayerInstall {
    /// The `reason` string the notification carries.
    #[allow(clippy::single_call_fn)]
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Replace => "replace",
            Self::Reconfigure => "reconfigure",
        }
    }
}

/// Posts [`LAYER_INSTALLED_NOTIFICATION`] on `center` for `layer`.
///
/// Delivery is synchronous on the calling thread, which production callers
/// keep on the main thread because the observer touches Core Animation.
fn announce_layer_installed(
    center: &NSNotificationCenter,
    layer: &AnyObject,
    display_id: u32,
    install: LayerInstall,
) {
    let name = NSString::from_str(LAYER_INSTALLED_NOTIFICATION);
    let display = NSNumber::new_u32(display_id);
    let reason = NSString::from_str(install.as_str());
    let objects: [&AnyObject; 2] = [&display, &reason];
    let user_info = NSDictionary::<NSString, AnyObject>::from_slices(
        &[ns_string!("displayID"), ns_string!("reason")],
        &objects,
    );
    // SAFETY: The generic parameters of an Objective-C collection are not part
    // of its runtime type; an observer reads the keys as strings and the
    // values as the documented number and string.
    let user_info = unsafe { objc2::rc::Retained::cast_unchecked::<NSDictionary>(user_info) };
    // SAFETY: `name` is a notification name and `layer` an arbitrary sender.
    unsafe { center.postNotificationName_object_userInfo(&name, Some(layer), Some(&user_info)) };
}

/// Borderless desktop-level window that hosts a `CAMetalLayer`.
pub struct WallpaperWindow {
    display: DisplayDesc,
    handle: Option<WindowHandle>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct MouseButtonState {
    pub button: u32,
    pub pressed: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct MouseButtons {
    mask: u64,
}

impl MouseButtons {
    #[must_use]
    #[allow(clippy::single_call_fn)]
    pub(crate) fn from_mask(mask: u64) -> Self {
        Self { mask }
    }

    #[cfg(test)]
    #[must_use]
    pub(crate) fn states(self) -> Vec<MouseButtonState> {
        (0..32)
            .map(|button| MouseButtonState {
                button,
                pressed: (self.mask & (1u64 << button)) != 0,
            })
            .collect()
    }

    #[must_use]
    pub(crate) fn mask(self) -> u64 {
        self.mask
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct MouseButtonEdges {
    down: MouseButtons,
    pressed: MouseButtons,
    released: MouseButtons,
}

impl MouseButtonEdges {
    #[must_use]
    pub(crate) fn from_level_state(buttons: MouseButtons) -> Self {
        Self {
            down: buttons,
            pressed: buttons,
            released: MouseButtons::default(),
        }
    }

    #[allow(clippy::single_call_fn)]
    #[must_use]
    pub(crate) fn from_masks(down: u64, pressed: u64, released: u64) -> Self {
        Self {
            down: MouseButtons::from_mask(down),
            pressed: MouseButtons::from_mask(pressed),
            released: MouseButtons::from_mask(released),
        }
    }

    /// Restores the level immediately before our press-then-release transitions.
    #[must_use]
    pub(crate) fn pre_transition_down_mask(self) -> u32 {
        ((self.down.mask | self.released.mask) & !self.pressed.mask & u64::from(u32::MAX)) as u32
    }

    #[cfg(test)]
    #[must_use]
    pub(crate) fn down(self) -> MouseButtons {
        self.down
    }

    #[cfg(test)]
    #[must_use]
    pub(crate) fn states(self) -> Vec<MouseButtonState> {
        let transitions = self.pressed.mask | self.released.mask;
        if transitions == 0 {
            return self.down.states();
        }

        (0..32)
            .flat_map(|button| {
                let mask = 1u64 << button;
                let mut states = Vec::with_capacity(2);
                if (self.pressed.mask & mask) != 0 {
                    states.push(MouseButtonState {
                        button,
                        pressed: true,
                    });
                }
                if (self.released.mask & mask) != 0 {
                    states.push(MouseButtonState {
                        button,
                        pressed: false,
                    });
                }
                if states.is_empty() {
                    states.push(MouseButtonState {
                        button,
                        pressed: (self.down.mask & mask) != 0,
                    });
                }
                states
            })
            .collect()
    }

    #[must_use]
    pub(crate) fn transitions(self) -> impl Iterator<Item = MouseButtonState> {
        let pressed = self.pressed.mask;
        let released = self.released.mask;
        let mut remaining = (pressed | released) & u64::from(u32::MAX);
        let mut pending_release = None;
        std::iter::from_fn(move || {
            if let Some(button) = pending_release.take() {
                return Some(MouseButtonState { button, pressed: false });
            }
            if remaining == 0 {
                return None;
            }
            let button = remaining.trailing_zeros();
            let mask = 1u64 << button;
            remaining &= !mask;
            let is_pressed = pressed & mask != 0;
            if is_pressed && released & mask != 0 {
                pending_release = Some(button);
            }
            Some(MouseButtonState { button, pressed: is_pressed })
        })
    }
}

/// Answers, for a button that just went down, whether the press landed on the
/// desktop rather than on another application's window. Asked on the main
/// thread, once per press; never for motion, held samples or a release.
pub(crate) type PressHitTest = Box<dyn FnMut() -> bool + Send>;

/// The OS button levels, and the edges the wallpapers receive from them.
///
/// Like Wallpaper Engine, which counts a press only while the window under
/// the cursor is the desktop or its own wallpaper, a press over another
/// application's window is withheld: the wallpapers see neither it, nor its
/// held level, nor its release. A press they did receive is always released,
/// wherever the pointer is by then, so a held state never sticks.
pub(crate) struct MouseButtonTracker {
    down: u64,
    /// Held buttons whose press landed on another application's window.
    withheld: u64,
    pressed: u64,
    released: u64,
    /// Nothing watched the buttons, because the pointer monitors were not
    /// installed, so `down` may be stale.
    levels_unknown: bool,
    press_on_desktop: PressHitTest,
}

impl MouseButtonTracker {
    /// A tracker for which every press lands on the desktop.
    #[cfg(test)]
    #[must_use]
    pub(crate) fn new() -> Self {
        Self::with_press_test(Box::new(|| true))
    }

    #[allow(clippy::single_call_fn)]
    #[must_use]
    pub(crate) fn with_press_test(press_on_desktop: PressHitTest) -> Self {
        Self { down: 0, withheld: 0, pressed: 0, released: 0, levels_unknown: false, press_on_desktop }
    }

    pub(crate) fn set_button(&mut self, button: u32, pressed: bool) {
        if button > 31 {
            return;
        }
        let mask = 1u64 << button;
        if pressed {
            if (self.down & mask) == 0 {
                self.down |= mask;
                self.press(mask);
            }
            return;
        }

        if (self.down & mask) != 0 {
            self.down &= !mask;
            self.release(mask);
        }
    }

    /// Records buttons that just went down, all at the cursor's one location.
    fn press(&mut self, buttons: u64) {
        if (self.press_on_desktop)() {
            self.pressed |= buttons;
        } else {
            self.withheld |= buttons;
        }
    }

    /// Records buttons that just went up; only a delivered press has a release.
    fn release(&mut self, buttons: u64) {
        self.released |= buttons & !self.withheld;
        self.withheld &= !buttons;
    }

    /// The monitors are going away (or never came): the next sample's buttons
    /// are levels to adopt, not edges.
    pub(crate) fn mark_levels_unknown(&mut self) {
        self.levels_unknown = true;
    }

    pub(crate) fn sync_down_mask(&mut self, mask: u64) {
        let next = mask & u64::from(u32::MAX);
        if self.levels_unknown {
            // A button held since before the monitors came back is not a new
            // press; edges the monitors did record meanwhile are kept. A held
            // button this tracker never saw go down could have been pressed
            // anywhere, so its level is adopted only if the pointer is over
            // the desktop now. One it did see keeps its verdict.
            self.levels_unknown = false;
            let unseen = next & !self.down;
            self.withheld &= next;
            if unseen != 0 && !(self.press_on_desktop)() {
                self.withheld |= unseen;
            }
            self.down = next;
            return;
        }
        let pressed = next & !self.down;
        let released = self.down & !next;
        self.down = next;
        if pressed != 0 {
            self.press(pressed);
        }
        self.release(released);
    }

    #[must_use]
    pub(crate) fn consume_edges(&mut self) -> MouseButtonEdges {
        let edges = MouseButtonEdges::from_masks(self.down & !self.withheld, self.pressed, self.released);
        self.pressed = 0;
        self.released = 0;
        edges
    }
}

/// What the pointer monitors report. Delivered on the AppKit main thread.
#[cfg(not(test))]
#[derive(Clone, Copy, Debug)]
pub(crate) enum MouseMonitorEvent {
    /// A button went down or up in another application. Recorded as an edge so
    /// a click shorter than the sampling spacing is not lost; the tracker
    /// withholds a press that landed on an application window.
    Button(MouseButtonState),
    /// Motion or a drag anywhere a monitor sees it, or a button in this app's
    /// own windows (read as a level by the next sample, as before).
    Motion,
    /// This application became active or inactive. While it is active AppKit
    /// sends pointer events to it, which the global monitor never sees.
    AppActive(bool),
}

#[cfg(not(test))]
pub(crate) struct MouseEventMonitor {
    global: Option<SendPtr>,
    local: Option<SendPtr>,
    activation_observers: [SendPtr; 2],
    #[allow(dead_code)]
    global_block: block2::RcBlock<dyn Fn(std::ptr::NonNull<NSEvent>)>,
    #[allow(dead_code)]
    local_block: block2::RcBlock<dyn Fn(std::ptr::NonNull<NSEvent>) -> *mut NSEvent>,
    #[allow(dead_code)]
    activation_blocks: [block2::RcBlock<dyn Fn(std::ptr::NonNull<objc2_foundation::NSNotification>)>; 2],
}

#[cfg(test)]
pub(crate) struct MouseEventMonitor;

#[cfg(not(test))]
impl MouseEventMonitor {
    /// Installs the global and local pointer monitors and the activation
    /// observers, then reports the current activation state. Main thread only.
    #[allow(clippy::single_call_fn)]
    pub(crate) fn new<F>(handler: F) -> Self
    where
        F: Fn(MouseMonitorEvent) + 'static,
    {
        let handler = std::rc::Rc::new(handler);

        let global_handler = std::rc::Rc::clone(&handler);
        let global_block = block2::RcBlock::new(move |event: std::ptr::NonNull<NSEvent>| {
            // SAFETY: AppKit invokes the monitor block with a valid NSEvent for
            // the event mask supplied when registering the monitor.
            let event = unsafe { event.as_ref() };
            global_handler(mouse_button_state_from_event(event)
                .map_or(MouseMonitorEvent::Motion, MouseMonitorEvent::Button));
        });
        let global = NSEvent::addGlobalMonitorForEventsMatchingMask_handler(
            pointer_event_mask(),
            &global_block,
        )
        .map(forget_token);

        let local_handler = std::rc::Rc::clone(&handler);
        let local_block = block2::RcBlock::new(move |event: std::ptr::NonNull<NSEvent>| {
            local_handler(MouseMonitorEvent::Motion);
            // Observe only: the event continues to its window unchanged.
            event.as_ptr()
        });
        // SAFETY: The block returns the event it was given, which is what a
        // local monitor must do to let the event through.
        let local = unsafe {
            NSEvent::addLocalMonitorForEventsMatchingMask_handler(pointer_event_mask(), &local_block)
        }
        .map(forget_token);

        let center = objc2_foundation::NSNotificationCenter::defaultCenter();
        let activation_blocks = [true, false].map(|active| {
            let handler = std::rc::Rc::clone(&handler);
            block2::RcBlock::new(move |_notification: std::ptr::NonNull<objc2_foundation::NSNotification>| {
                handler(MouseMonitorEvent::AppActive(active));
            })
        });
        // SAFETY: The names are AppKit's constant notification names; a nil
        // queue delivers on the posting thread, which for these is main.
        let activation_observers = unsafe {
            [
                objc2_app_kit::NSApplicationDidBecomeActiveNotification,
                objc2_app_kit::NSApplicationDidResignActiveNotification,
            ]
        }
        .into_iter()
        .zip(&activation_blocks)
        .map(|(name, block)| {
            // SAFETY: See above; the block is retained by this monitor for as
            // long as the observer is registered.
            let token = unsafe {
                center.addObserverForName_object_queue_usingBlock(Some(name), None, None, block)
            };
            forget_token(token)
        })
        .collect::<Vec<_>>();
        let activation_observers = [activation_observers[0], activation_observers[1]];

        // Observers first, then the current state: both run on the main thread,
        // so no activation change can fall between them.
        handler(MouseMonitorEvent::AppActive(
            objc2_app_kit::NSRunningApplication::currentApplication().isActive(),
        ));
        if global.is_none() || local.is_none() {
            log::warn!(
                "pointer event monitor unavailable (global: {}, local: {}); pointer sampling \
                 falls back to checking the cursor",
                global.is_some(),
                local.is_some()
            );
        }

        Self { global, local, activation_observers, global_block, local_block, activation_blocks }
    }

    /// Both monitors installed, so outside the active-app gap every pointer
    /// change reaches the handler.
    pub(crate) fn complete(&self) -> bool {
        self.global.is_some() && self.local.is_some()
    }
}

#[cfg(not(test))]
fn forget_token<T: ?Sized + Message>(token: Retained<T>) -> SendPtr {
    let pointer = SendPtr(Retained::as_ptr(&token).cast_mut().cast());
    std::mem::forget(token);
    pointer
}

#[cfg(not(test))]
impl Drop for MouseEventMonitor {
    fn drop(&mut self) {
        let monitors: Vec<usize> =
            [self.global, self.local].into_iter().flatten().map(|token| token.0 as usize).collect();
        let observers = self.activation_observers.map(|token| token.0 as usize);
        run_on_main_thread(move || unsafe {
            let token = |raw: usize| {
                Retained::from_raw((raw as *mut std::ffi::c_void).cast::<AnyObject>())
                    .expect("pointer monitor token should not be null")
            };
            for monitor in monitors {
                NSEvent::removeMonitor(&token(monitor));
            }
            let center = objc2_foundation::NSNotificationCenter::defaultCenter();
            for observer in observers {
                center.removeObserver(&token(observer));
            }
        });
    }
}

// SAFETY: The monitor and observer tokens are retained and only removed on the
// AppKit main thread in Drop. The retained blocks must stay alive for AppKit
// callbacks, but they are not invoked by Rust after construction.
#[cfg(not(test))]
unsafe impl Send for MouseEventMonitor {}
// SAFETY: The wrapper stores Objective-C tokens opaquely and all Objective-C
// interaction is dispatched to the main thread.
#[cfg(not(test))]
unsafe impl Sync for MouseEventMonitor {}

#[cfg(not(test))]
#[must_use]
#[allow(clippy::single_call_fn)]
fn pointer_event_mask() -> NSEventMask {
    NSEventMask::LeftMouseDown
        | NSEventMask::LeftMouseUp
        | NSEventMask::RightMouseDown
        | NSEventMask::RightMouseUp
        | NSEventMask::OtherMouseDown
        | NSEventMask::OtherMouseUp
        | NSEventMask::MouseMoved
        | NSEventMask::LeftMouseDragged
        | NSEventMask::RightMouseDragged
        | NSEventMask::OtherMouseDragged
}

/// Reads the cursor location and the three primary buttons without the main
/// thread. Used only as a change detector; the sample scenes receive still
/// comes from `NSEvent` on the main thread, so no coordinate conversion is
/// needed here. An unreadable location compares unequal, which samples.
pub(crate) fn probe_pointer() -> crate::engine::PointerProbe {
    use objc2_core_graphics::{CGEvent, CGEventSource, CGEventSourceStateID, CGMouseButton};

    let (x, y) = CGEvent::new(None).map_or((f64::NAN, f64::NAN), |event| {
        let location = CGEvent::location(Some(&event));
        (location.x, location.y)
    });
    let buttons = [CGMouseButton::Left, CGMouseButton::Right, CGMouseButton::Center]
        .into_iter()
        .enumerate()
        .filter(|&(_, button)| {
            CGEventSource::button_state(CGEventSourceStateID::CombinedSessionState, button)
        })
        .fold(0u32, |mask, (bit, _)| mask | (1 << bit));
    crate::engine::PointerProbe { x, y, buttons }
}

#[cfg(not(test))]
#[must_use]
#[allow(clippy::single_call_fn)]
fn mouse_button_state_from_event(event: &NSEvent) -> Option<MouseButtonState> {
    let event_type = event.r#type();
    let pressed = if event_type == NSEventType::LeftMouseDown
        || event_type == NSEventType::RightMouseDown
        || event_type == NSEventType::OtherMouseDown
    {
        true
    } else if event_type == NSEventType::LeftMouseUp
        || event_type == NSEventType::RightMouseUp
        || event_type == NSEventType::OtherMouseUp
    {
        false
    } else {
        return None;
    };

    let button = match event_type {
        NSEventType::LeftMouseDown | NSEventType::LeftMouseUp => 0,
        NSEventType::RightMouseDown | NSEventType::RightMouseUp => 1,
        _ => u32::try_from(event.buttonNumber()).ok()?,
    };

    Some(MouseButtonState { button, pressed })
}

/// Whether a press at the cursor lands on the desktop: the [`PressHitTest`]
/// the engine's tracker uses. The window server names the window a mouse-down
/// there would hit; our wallpaper windows ignore the mouse, so over the
/// desktop that is Finder's icon window or the system wallpaper. Main thread
/// only, and two window-server round trips, so it runs once per press.
#[allow(clippy::single_call_fn)]
pub(crate) fn press_lands_on_desktop() -> bool {
    let Some(mtm) = MainThreadMarker::new() else {
        debug_assert!(false, "pointer presses are hit-tested on the main thread");
        return true;
    };
    let point = objc2_app_kit::NSEvent::mouseLocation();
    let window = NSWindow::windowNumberAtPoint_belowWindowWithWindowNumber(point, 0, mtm);
    window_counts_as_desktop(window, window_layer)
}

/// The rule web wallpapers route by (`WebWallpaperMouseRouting`): the desktop
/// is everything the window server stacks beneath ordinary application
/// windows, which all report a negative layer: the system wallpaper, Finder's
/// icons, desktop widgets and our own wallpaper windows. No window, or one
/// that closed before its layer was read, leaves nothing covering the desktop.
#[allow(clippy::single_call_fn)]
fn window_counts_as_desktop(window: NSInteger, layer: impl FnOnce(NSInteger) -> Option<i64>) -> bool {
    window <= 0 || layer(window).is_none_or(|layer| layer < 0)
}

/// A window's `kCGWindowLayer`, or `None` once it is gone.
#[allow(clippy::single_call_fn)]
fn window_layer(window: NSInteger) -> Option<i64> {
    use objc2_core_foundation::{CFArray, CFDictionary, CFNumber, CFRetained, CFString, CFType};
    use objc2_core_graphics::{CGWindowListCopyWindowInfo, CGWindowListOption, kCGWindowLayer};

    let window = u32::try_from(window).ok()?;
    let descriptions = CGWindowListCopyWindowInfo(CGWindowListOption::OptionIncludingWindow, window)?;
    // SAFETY: CoreGraphics documents the window list as an array of
    // dictionaries keyed by `CFString`.
    let descriptions = unsafe {
        CFRetained::cast_unchecked::<CFArray<CFDictionary<CFString, CFType>>>(descriptions)
    };
    // SAFETY: `kCGWindowLayer` is an immutable CoreGraphics constant.
    let layer = descriptions.get(0)?.get(unsafe { kCGWindowLayer })?;
    layer.downcast_ref::<CFNumber>()?.as_i64()
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct NormalizedMousePosition {
    pub x: f64,
    pub y: f64,
}

impl NormalizedMousePosition {
    #[must_use]
    #[allow(clippy::single_call_fn)]
    pub fn from_window_point(x: f64, y: f64, width: f64, height: f64) -> Option<Self> {
        if !x.is_finite() || !y.is_finite() || !width.is_finite() || !height.is_finite() {
            return None;
        }
        if width <= 0.0 || height <= 0.0 {
            return None;
        }

        Some(Self {
            x: (x / width).clamp(0.0, 1.0),
            y: (1.0 - (y / height)).clamp(0.0, 1.0),
        })
    }
}

impl WallpaperWindow {
    /// Starts building a wallpaper window for `display`.
    #[must_use]
    pub fn builder(display: DisplayDesc) -> WallpaperWindowBuilder {
        WallpaperWindowBuilder {
            display,
            style: PlaceholderStyle::default(),
        }
    }

    /// Closes the native window if it is still open.
    pub fn close(&mut self) {
        if let Some(handle) = self.handle.take() {
            MainThread::dispatch(move || unsafe {
                handle.close_on_main();
            });
        }
    }

    /// Updates the native window, content view, and Metal layer to match
    /// `display`.
    ///
    /// # Errors
    ///
    /// Returns an error if the display geometry is invalid or the window has
    /// been closed.
    pub fn update_display(&mut self, display: DisplayDesc) -> Result<(), EngineError> {
        if display.display_id == 0 {
            return Err(EngineError::InvalidInput(
                "display_id must be non-zero".to_string(),
            ));
        }
        if display.width == 0 || display.height == 0 {
            return Err(EngineError::InvalidInput(
                "display dimensions must be non-zero".to_string(),
            ));
        }
        let Some(handle) = self.handle.as_ref() else {
            return Err(EngineError::Platform(
                "wallpaper window is already closed".to_string(),
            ));
        };

        let display_for_update = display.clone();
        let handle = handle.clone_for_main_thread();
        MainThread::dispatch(move || unsafe {
            handle.update_display(&display_for_update);
        });
        self.display = display;
        Ok(())
    }

    /// Returns whether this Rust-owned window still has a native handle.
    #[must_use]
    pub fn is_open(&self) -> bool {
        self.handle.is_some()
    }

    /// Replaces the `CAMetalLayer` under the existing `NSView` and returns the
    /// new layer's raw pointer, cast to `*mut c_void`. Used during
    /// display-reconfigure transactions: the returned pointer is passed to
    /// `OweScene::finish_surface_reconfigure`.
    ///
    /// # Errors
    ///
    /// Returns an error if the display geometry is invalid or the window has
    /// been closed.
    ///
    /// The `NSWindow` and `NSView` are retained. The old `CAMetalLayer` is
    /// released after the new layer is installed, so this replacement cannot be
    /// undone; a caller that might have to put the old layer back uses
    /// `begin_layer_swap`. The new layer is announced with
    /// [`LAYER_INSTALLED_NOTIFICATION`] as a `reconfigure`.
    pub fn update_layer(
        &mut self,
        display: DisplayDesc,
    ) -> Result<*mut std::ffi::c_void, EngineError> {
        let swap = self.begin_layer_swap(display, LayerInstall::Reconfigure)?;
        let layer = swap.layer_ptr();
        swap.finish();
        Ok(layer)
    }

    /// Installs a fresh `CAMetalLayer` under the existing `NSView` and keeps
    /// the layer it replaced, so the replacement can still be undone.
    ///
    /// The new layer is announced with [`LAYER_INSTALLED_NOTIFICATION`] as
    /// soon as it is under the view and shaped, before any renderer exists.
    /// A swap that is then reverted takes the announced layer out again
    /// without a further notification.
    ///
    /// The caller opens its renderer on [`LayerSwap::layer_ptr`] and then
    /// either confirms the swap with [`LayerSwap::finish`] or undoes it with
    /// [`Self::revert_layer_swap`].
    ///
    /// # Errors
    ///
    /// Returns an error if the display geometry is invalid or the window has
    /// been closed.
    pub(crate) fn begin_layer_swap(
        &mut self,
        display: DisplayDesc,
        install: LayerInstall,
    ) -> Result<LayerSwap, EngineError> {
        if display.display_id == 0 {
            return Err(EngineError::InvalidInput(
                "display_id must be non-zero".to_string(),
            ));
        }
        if display.width == 0 || display.height == 0 {
            return Err(EngineError::InvalidInput(
                "display dimensions must be non-zero".to_string(),
            ));
        }
        let previous_display = self.display.clone();
        let Some(handle) = self.handle.as_mut() else {
            return Err(EngineError::Platform(
                "wallpaper window is already closed".to_string(),
            ));
        };

        let handle_ref = handle.clone_for_main_thread();
        let display_clone = display.clone();
        let SendPtr(new_layer_ptr) = MainThread::dispatch(move || unsafe {
            handle_ref.replace_metal_layer(&display_clone, install)
        })?;

        // Track the new layer in the window and hold on to the old wrapper
        // instead of releasing it.
        let ptr_for_retain = SendPtr(new_layer_ptr);
        let previous = std::mem::replace(
            &mut handle.metal_layer,
            MainThread::dispatch(move || unsafe { MainThread::retain_from_ptr(ptr_for_retain) })?,
        );

        self.display = display;
        Ok(LayerSwap {
            layer: SendPtr(new_layer_ptr),
            previous,
            previous_display,
        })
    }

    /// Undoes [`Self::begin_layer_swap`]: puts the previous `CAMetalLayer`
    /// back under the `NSView`, restores the window, view and layer geometry
    /// of the display it was installed for, and releases the layer that
    /// replaced it.
    ///
    /// Call it only after whatever was opened on the new layer is closed, so
    /// nothing else holds on to that layer.
    ///
    /// # Errors
    ///
    /// Returns an error if the window has been closed; the previous layer is
    /// released with the window in that case.
    #[allow(clippy::single_call_fn)]
    pub(crate) fn revert_layer_swap(&mut self, swap: LayerSwap) -> Result<(), EngineError> {
        let LayerSwap {
            previous,
            previous_display,
            ..
        } = swap;
        let Some(handle) = self.handle.as_mut() else {
            MainThread::dispatch(move || unsafe { previous.release() });
            return Err(EngineError::Platform(
                "wallpaper window is already closed".to_string(),
            ));
        };

        let handle_ref = handle.clone_for_main_thread();
        let previous_ptr = SendPtr(previous.as_ptr().cast::<std::ffi::c_void>());
        let abandoned = std::mem::replace(&mut handle.metal_layer, previous);
        let display_for_main = previous_display.clone();
        MainThread::dispatch(move || unsafe {
            handle_ref.restore_metal_layer(previous_ptr, &display_for_main);
            abandoned.release();
        });

        self.display = previous_display;
        Ok(())
    }

    /// Returns the retained `CAMetalLayer` pointer used by Vulkan/MoltenVK.
    ///
    /// The pointer is null after close. Callers must not outlive the returned
    /// pointer beyond the `WallpaperWindow` that owns it.
    #[must_use]
    pub fn metal_layer_ptr(&self) -> *mut std::ffi::c_void {
        self.handle.as_ref().map_or(std::ptr::null_mut(), |handle| {
            handle.metal_layer.as_ptr().cast::<std::ffi::c_void>()
        })
    }

    #[cfg(test)]
    /// # Errors
    ///
    /// Returns an error if the window has been closed.
    pub fn native_state_for_tests(&self) -> Result<WallpaperWindowNativeState, EngineError> {
        let Some(handle) = self.handle.as_ref() else {
            return Err(EngineError::Platform(
                "wallpaper window is already closed".to_string(),
            ));
        };

        let handle = handle.clone_for_main_thread();
        Ok(MainThread::dispatch(move || unsafe {
            handle.native_state()
        }))
    }
}

#[cfg(test)]
pub struct WallpaperWindowNativeState {
    pub window_x: f64,
    pub window_y: f64,
    pub window_width: f64,
    pub window_height: f64,
    pub content_view_x: f64,
    pub content_view_y: f64,
    pub content_view_width: f64,
    pub content_view_height: f64,
    pub metal_layer_x: f64,
    pub metal_layer_y: f64,
    pub metal_layer_width: f64,
    pub metal_layer_height: f64,
    pub metal_layer_contents_scale: f64,
    pub metal_layer_drawable_width: f64,
    pub metal_layer_drawable_height: f64,
}

/// A `CAMetalLayer` replacement that is installed but not yet settled.
///
/// [`WallpaperWindow::begin_layer_swap`] puts a fresh layer under the view and
/// keeps the layer it replaced alive here. Whoever opens a renderer on the new
/// layer then settles the swap exactly once: [`LayerSwap::finish`] when the
/// renderer exists, [`WallpaperWindow::revert_layer_swap`] when it could not be
/// built, which shows the previous layer, and the renderer still drawing on it,
/// again. Both consume the value, so a swap cannot be settled twice.
#[must_use = "a layer swap must be finished or reverted, or the previous layer leaks"]
pub(crate) struct LayerSwap {
    layer: SendPtr,
    previous: MainThread,
    previous_display: DisplayDesc,
}

impl LayerSwap {
    /// The new layer, as a renderer's surface takes it.
    pub(crate) fn layer_ptr(&self) -> *mut std::ffi::c_void {
        self.layer.0
    }

    /// Keeps the new layer: releases the one it replaced.
    ///
    /// A renderer's surface on the previous layer keeps its own retain until
    /// that renderer is closed.
    pub(crate) fn finish(self) {
        let Self { previous, .. } = self;
        MainThread::dispatch(move || unsafe { previous.release() });
    }
}

impl Drop for WallpaperWindow {
    fn drop(&mut self) {
        self.close();
    }
}

/// Builder for a Rust-owned wallpaper window.
pub struct WallpaperWindowBuilder {
    display: DisplayDesc,
    style: PlaceholderStyle,
}

impl WallpaperWindowBuilder {
    /// Sets the placeholder color used before content is presented.
    #[must_use]
    pub fn placeholder_style(mut self, style: PlaceholderStyle) -> Self {
        self.style = style;
        self
    }

    /// Opens the native window.
    ///
    /// # Errors
    ///
    /// Returns an error if the display geometry is invalid or `AppKit` window
    /// creation fails.
    ///
    /// # Panics
    ///
    /// Panics only if main-thread dispatch does not return a result.
    pub fn open(self) -> Result<WallpaperWindow, EngineError> {
        if self.display.display_id == 0 {
            return Err(EngineError::InvalidInput(
                "display_id must be non-zero".to_string(),
            ));
        }
        if self.display.width == 0 || self.display.height == 0 {
            return Err(EngineError::InvalidInput(
                "display dimensions must be non-zero".to_string(),
            ));
        }

        MainThread::dispatch(|| unsafe {
            objc2::rc::autoreleasepool(|_| {
                let maker = MainThreadMarker::new().unwrap();
                let scale_factor = if self.display.scale_factor > 0.0 {
                    self.display.scale_factor
                } else {
                    1.0
                };
                let point_width = f64::from(self.display.width) / scale_factor;
                let point_height = f64::from(self.display.height) / scale_factor;
                let frame = NSRect::new(
                    NSPoint::new(f64::from(self.display.x), f64::from(self.display.y)),
                    NSSize::new(point_width, point_height),
                );
                let content_frame =
                    NSRect::new(NSPoint::ZERO, NSSize::new(point_width, point_height));

                let application = NSApplication::sharedApplication(maker);
                application.finishLaunching();

                let wallpaper_window = WallpaperDesktopWindow::init_with_content_rect(
                    maker,
                    frame,
                    NSWindowStyleMask::Borderless,
                    NSBackingStoreType::Buffered,
                    false,
                );
                let window = wallpaper_window.as_super();
                window.setReleasedWhenClosed(false);

                let window_level =
                    CGWindowLevelForKey(CGWindowLevelKey::DesktopWindowLevelKey) as NSInteger;
                let window_color = NSColor::colorWithSRGBRed_green_blue_alpha(
                    self.style.red,
                    self.style.green,
                    self.style.blue,
                    self.style.alpha,
                );

                window.setLevel(window_level);
                window.setCollectionBehavior(
                    NSWindowCollectionBehavior::CanJoinAllSpaces
                        | NSWindowCollectionBehavior::Stationary
                        | NSWindowCollectionBehavior::FullScreenAuxiliary
                        | NSWindowCollectionBehavior::IgnoresCycle,
                );
                window.setOpaque(true);
                window.setHasShadow(false);
                window.setMovable(false);
                window.setRestorable(false);
                window.setIgnoresMouseEvents(true);
                window.setHidesOnDeactivate(false);
                // The desktop belongs to the wallpaper, not to the app: hiding
                // the app (Cmd-H, or hiding the panel after an apply) must not
                // take every display's wallpaper off screen with it.
                window.setCanHide(false);
                window.setExcludedFromWindowsMenu(true);
                window.setAnimationBehavior(NSWindowAnimationBehavior::None);
                window.setBackgroundColor(Some(&window_color));

                let content_view = NSView::initWithFrame(NSView::alloc(maker), content_frame);
                content_view.setWantsLayer(true);

                let metal_layer = self.display.build_metal_layer(&self.style);

                content_view.setLayer(Some(&metal_layer));
                window.setContentView(Some(&content_view));

                let window_handle = MainThread::retain(window, "NSWindow")?;
                let metal_layer_handle = match MainThread::retain(&metal_layer, "CAMetalLayer") {
                    Ok(handle) => handle,
                    Err(error) => {
                        window_handle.release();
                        return Err(error);
                    }
                };
                let content_view_handle = match MainThread::retain(&content_view, "NSView") {
                    Ok(handle) => handle,
                    Err(error) => {
                        window_handle.release();
                        metal_layer_handle.release();
                        return Err(error);
                    }
                };

                // The layer is announced before the window is ordered front,
                // so an observer can put content on it before the first
                // composite.
                announce_layer_installed(
                    &NSNotificationCenter::defaultCenter(),
                    &metal_layer,
                    self.display.display_id,
                    LayerInstall::Open,
                );
                window.orderFrontRegardless();

                Ok(WallpaperWindow {
                    display: self.display,
                    handle: Some(WindowHandle {
                        window: window_handle,
                        content_view: content_view_handle,
                        metal_layer: metal_layer_handle,
                    }),
                })
            })
        })
    }
}

/// A raw pointer wrapper that is `Send`.
///
/// SAFETY: The pointer originates from an Objective-C object that is
/// reference-counted and thread-safe at the ARC level. We only transport the
/// pointer value across the dispatch boundary; actual dereferences happen
/// exclusively on the main thread.
#[derive(Clone, Copy)]
struct SendPtr(*mut std::ffi::c_void);
unsafe impl Send for SendPtr {}

struct MainThreadDispatchContext<F, R> {
    body: Option<F>,
    result: Option<std::thread::Result<R>>,
}

#[allow(clippy::single_call_fn)]
extern "C" fn invoke_main_thread_body<F, R>(context: *mut std::ffi::c_void)
where
    F: FnOnce() -> R + Send,
    R: Send,
{
    let context = unsafe { &mut *context.cast::<MainThreadDispatchContext<F, R>>() };
    let body = context
        .body
        .take()
        .expect("main-thread body should run exactly once");
    context.result = Some(std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)));
}

struct WindowHandle {
    window: MainThread,
    content_view: MainThread,
    metal_layer: MainThread,
}

impl WindowHandle {
    fn clone_for_main_thread(&self) -> WindowHandleRef {
        WindowHandleRef {
            window: self.window.as_ptr(),
            content_view: self.content_view.as_ptr(),
            metal_layer: self.metal_layer.as_ptr(),
        }
    }

    unsafe fn close_on_main(self) {
        debug_assert!(NSThread::isMainThread_class());
        let window = unsafe { &*(self.window.as_ptr().cast::<NSWindow>()) };
        window.orderOut(None);
        window.close();
        unsafe {
            self.window.release();
            self.content_view.release();
            self.metal_layer.release();
        }
    }
}

struct WindowHandleRef {
    window: *mut AnyObject,
    content_view: *mut AnyObject,
    metal_layer: *mut AnyObject,
}

// SAFETY: These raw pointers are borrowed from an open `WallpaperWindow` and
// are only used inside synchronous `run_on_main_sync` operations. Safe Rust
// borrowing prevents the owner from being closed or dropped while the borrowed
// pointers are in flight.
unsafe impl Send for WindowHandleRef {}

impl WindowHandleRef {
    #[cfg(test)]
    unsafe fn native_state(self) -> WallpaperWindowNativeState {
        debug_assert!(NSThread::isMainThread_class());
        let window = unsafe { &*(self.window.cast::<NSWindow>()) };
        let content_view = unsafe { &*(self.content_view.cast::<NSView>()) };
        let metal_layer = unsafe { &*(self.metal_layer.cast::<CAMetalLayer>()) };

        let window_frame = window.frame();
        let content_view_frame = content_view.frame();
        let metal_layer_frame = metal_layer.frame();
        let drawable_size = metal_layer.drawableSize();

        WallpaperWindowNativeState {
            window_x: window_frame.origin.x,
            window_y: window_frame.origin.y,
            window_width: window_frame.size.width,
            window_height: window_frame.size.height,
            content_view_x: content_view_frame.origin.x,
            content_view_y: content_view_frame.origin.y,
            content_view_width: content_view_frame.size.width,
            content_view_height: content_view_frame.size.height,
            metal_layer_x: metal_layer_frame.origin.x,
            metal_layer_y: metal_layer_frame.origin.y,
            metal_layer_width: metal_layer_frame.size.width,
            metal_layer_height: metal_layer_frame.size.height,
            metal_layer_contents_scale: metal_layer.contentsScale(),
            metal_layer_drawable_width: drawable_size.width,
            metal_layer_drawable_height: drawable_size.height,
        }
    }

    unsafe fn update_display(self, display: &DisplayDesc) {
        debug_assert!(NSThread::isMainThread_class());
        let scale_factor = if display.scale_factor > 0.0 {
            display.scale_factor
        } else {
            1.0
        };
        let point_width = f64::from(display.width) / scale_factor;
        let point_height = f64::from(display.height) / scale_factor;
        let frame = NSRect::new(
            NSPoint::new(f64::from(display.x), f64::from(display.y)),
            NSSize::new(point_width, point_height),
        );
        let content_frame = NSRect::new(NSPoint::ZERO, NSSize::new(point_width, point_height));
        let drawable_size = NSSize::new(f64::from(display.width), f64::from(display.height));

        let window = unsafe { &*(self.window.cast::<NSWindow>()) };
        let content_view = unsafe { &*(self.content_view.cast::<NSView>()) };
        let metal_layer = unsafe { &*(self.metal_layer.cast::<CAMetalLayer>()) };

        // A primary-display or origin change is not a new render surface.
        // Redrawing the window or resetting its drawable during wake exposes
        // the placeholder before the suspended renderer can present again.
        CATransaction::begin();
        CATransaction::setDisableActions(true);
        if window.frame() != frame {
            window.setFrame_display(frame, false);
        }
        if content_view.frame() != content_frame {
            content_view.setFrame(content_frame);
        }
        if metal_layer.frame() != content_frame {
            metal_layer.setFrame(content_frame);
        }
        if metal_layer.contentsScale() != scale_factor {
            metal_layer.setContentsScale(scale_factor);
        }
        if metal_layer.drawableSize() != drawable_size {
            metal_layer.setDrawableSize(drawable_size);
        }
        CATransaction::commit();
    }

    /// Puts `previous` back under the view in place of the layer installed by
    /// `replace_metal_layer`, then restores the geometry of `display`.
    ///
    /// The geometry goes through `update_display` aimed at the previous layer,
    /// so values that already match are not written again: an untouched
    /// layer keeps its drawables.
    unsafe fn restore_metal_layer(self, previous: SendPtr, display: &DisplayDesc) {
        debug_assert!(NSThread::isMainThread_class());
        let content_view = unsafe { &*(self.content_view.cast::<NSView>()) };
        let previous_layer = unsafe { &*(previous.0.cast::<CAMetalLayer>()) };

        CATransaction::begin();
        CATransaction::setDisableActions(true);
        content_view.setLayer(Some(previous_layer));
        content_view.setWantsLayer(true);
        unsafe {
            Self {
                metal_layer: previous.0.cast::<AnyObject>(),
                ..self
            }
            .update_display(display);
        }
        CATransaction::commit();
    }

    /// Installs a fresh layer under the view, shapes the window for `display`
    /// and announces the layer as `install`.
    #[allow(clippy::unnecessary_wraps)]
    unsafe fn replace_metal_layer(
        self,
        display: &DisplayDesc,
        install: LayerInstall,
    ) -> Result<SendPtr, EngineError> {
        debug_assert!(NSThread::isMainThread_class());

        let new_layer = display.build_metal_layer(&PlaceholderStyle::default());

        // Install on the NSView.
        let content_view = unsafe { &*(self.content_view.cast::<NSView>()) };
        content_view.setLayer(Some(&new_layer));
        content_view.setWantsLayer(true);

        // Reshape window/view geometry.
        let scale_factor = if display.scale_factor > 0.0 {
            display.scale_factor
        } else {
            1.0
        };
        let point_width = f64::from(display.width) / scale_factor;
        let point_height = f64::from(display.height) / scale_factor;
        let frame = NSRect::new(
            NSPoint::new(f64::from(display.x), f64::from(display.y)),
            NSSize::new(point_width, point_height),
        );
        let content_frame = NSRect::new(NSPoint::ZERO, NSSize::new(point_width, point_height));
        let drawable_size = NSSize::new(f64::from(display.width), f64::from(display.height));

        let window = unsafe { &*(self.window.cast::<NSWindow>()) };
        window.setFrame_display(frame, true);
        content_view.setFrame(content_frame);
        new_layer.setFrame(content_frame);
        new_layer.setContentsScale(scale_factor);
        new_layer.setDrawableSize(drawable_size);

        announce_layer_installed(
            &NSNotificationCenter::defaultCenter(),
            &new_layer,
            display.display_id,
            install,
        );

        let ptr: *mut std::ffi::c_void = Retained::as_ptr(&new_layer).cast_mut().cast();
        Ok(SendPtr(ptr))
    }
}

pub struct MainThread {
    object: std::mem::ManuallyDrop<Retained<AnyObject>>,
}

impl MainThread {
    #[allow(clippy::unnecessary_wraps)]
    unsafe fn retain(object: &AnyObject, _label: &str) -> Result<Self, EngineError> {
        debug_assert!(objc2_foundation::NSThread::isMainThread_class());
        Ok(Self {
            object: std::mem::ManuallyDrop::new(object.retain()),
        })
    }

    #[allow(clippy::needless_pass_by_value, clippy::single_call_fn)]
    unsafe fn retain_from_ptr(ptr: SendPtr) -> Result<Self, EngineError> {
        debug_assert!(objc2_foundation::NSThread::isMainThread_class());
        if ptr.0.is_null() {
            return Err(EngineError::Platform(
                "MainThread::retain_from_ptr received null".to_string(),
            ));
        }

        unsafe {
            let object = &*(ptr.0.cast::<AnyObject>());
            Self::retain(object, "CAMetalLayer (replaced)")
        }
    }

    fn as_ptr(&self) -> *mut AnyObject {
        Retained::as_ptr(&self.object).cast_mut()
    }

    unsafe fn release(mut self) {
        debug_assert!(objc2_foundation::NSThread::isMainThread_class());
        unsafe { std::mem::ManuallyDrop::drop(&mut self.object) };
    }

    pub fn dispatch<F, R>(body: F) -> R
    where
        F: FnOnce() -> R + Send,
        R: Send,
    {
        if objc2_foundation::NSThread::isMainThread_class() {
            return body();
        }

        let mut context = MainThreadDispatchContext {
            body: Some(body),
            result: None,
        };

        // The stack context is valid for the duration of dispatch_sync_f because
        // the call blocks until the main queue has executed `invoke`.
        unsafe {
            dispatch2::DispatchQueue::main()
                .exec_sync_f((&raw mut context).cast(), invoke_main_thread_body::<F, R>);
        }

        match context
            .result
            .expect("main-thread body should complete before dispatch_sync_f returns")
        {
            Ok(result) => result,
            Err(payload) => std::panic::resume_unwind(payload),
        }
    }
}

#[allow(clippy::single_call_fn)]
pub(crate) fn run_on_main_thread<F, R>(body: F) -> R
where
    F: FnOnce() -> R + Send,
    R: Send,
{
    MainThread::dispatch(body)
}

// SAFETY: This is an owned Objective-C pointer token, not a native facade. It
// may move between Rust threads, but retains, releases, and Objective-C message
// sends are only performed by the main-thread window path above.
unsafe impl Send for MainThread {}

#[cfg(test)]
mod tests {
    use super::{
        LAYER_INSTALLED_NOTIFICATION, LayerInstall, MouseButtonEdges, MouseButtonState,
        MouseButtonTracker, MouseButtons, NormalizedMousePosition, announce_layer_installed,
        window_counts_as_desktop,
    };
    use objc2::{rc::Retained, runtime::AnyObject};
    use objc2_core_graphics::{CGWindowLevelForKey, CGWindowLevelKey};
    use objc2_foundation::{
        NSNotification, NSNotificationCenter, NSNumber, NSObject, NSString, ns_string,
    };
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    };

    /// What an observer of the layer announcement read from one notification.
    #[derive(Debug, PartialEq, Eq)]
    struct Announcement {
        layer: usize,
        display_id: u32,
        reason: String,
        thread: std::thread::ThreadId,
    }

    fn observe_announcements(
        center: &NSNotificationCenter,
        sender: Option<&AnyObject>,
    ) -> (Arc<Mutex<Vec<Announcement>>>, Retained<AnyObject>) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&seen);
        let block = block2::RcBlock::new(move |notification: std::ptr::NonNull<NSNotification>| {
            // SAFETY: The center hands the block a live notification.
            let notification = unsafe { notification.as_ref() };
            let layer = notification.object().expect("the layer is the notification's object");
            let info = notification.userInfo().expect("the announcement carries user info");
            let display = info
                .objectForKey(ns_string!("displayID"))
                .and_then(|value| value.downcast::<NSNumber>().ok())
                .expect("displayID is a number");
            let reason = info
                .objectForKey(ns_string!("reason"))
                .and_then(|value| value.downcast::<NSString>().ok())
                .expect("reason is a string");
            sink.lock().unwrap().push(Announcement {
                layer: Retained::as_ptr(&layer) as usize,
                display_id: display.as_u32(),
                reason: reason.to_string(),
                thread: std::thread::current().id(),
            });
        });
        let name = NSString::from_str(LAYER_INSTALLED_NOTIFICATION);
        // SAFETY: A nil queue delivers on the posting thread; the block is
        // copied by the center and the token is removed by the caller.
        let token =
            unsafe { center.addObserverForName_object_queue_usingBlock(Some(&name), sender, None, &block) };
        (seen, token.into())
    }

    #[test]
    fn announcement_carries_display_and_reason() {
        let center = NSNotificationCenter::new();
        let (seen, token) = observe_announcements(&center, None);
        let layers = [NSObject::new(), NSObject::new(), NSObject::new()];
        // An observer on the default center, aimed at one of these layers, must
        // not hear what is announced on the private center.
        let (default_center_seen, default_token) =
            observe_announcements(&NSNotificationCenter::defaultCenter(), Some(&layers[0]));

        for (layer, (display_id, install)) in layers.iter().zip([
            (1, LayerInstall::Open),
            (69_733_254, LayerInstall::Replace),
            (u32::MAX, LayerInstall::Reconfigure),
        ]) {
            announce_layer_installed(&center, layer, display_id, install);
        }
        // SAFETY: The tokens came from the matching `addObserver` calls above.
        unsafe {
            center.removeObserver(&token);
            NSNotificationCenter::defaultCenter().removeObserver(&default_token);
        }

        let thread = std::thread::current().id();
        let expected = [(1, "open"), (69_733_254, "replace"), (u32::MAX, "reconfigure")];
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), expected.len(), "one announcement per install, in order");
        for ((announcement, layer), (display_id, reason)) in seen.iter().zip(&layers).zip(expected) {
            assert_eq!(announcement.layer, Retained::as_ptr(layer) as usize, "object is the layer");
            assert_eq!(announcement.display_id, display_id);
            assert_eq!(announcement.reason, reason);
            assert_eq!(announcement.thread, thread, "delivered synchronously on the posting thread");
        }
        assert!(default_center_seen.lock().unwrap().is_empty());
    }

    #[test]
    fn install_reason_strings_are_the_swift_contract() {
        // The Swift observer matches these literally.
        assert_eq!(LAYER_INSTALLED_NOTIFICATION, "WallpaperMachine.wallpaperLayerInstalled");
        assert_eq!(LayerInstall::Open.as_str(), "open");
        assert_eq!(LayerInstall::Replace.as_str(), "replace");
        assert_eq!(LayerInstall::Reconfigure.as_str(), "reconfigure");
    }

    #[test]
    fn mouse_edge_iterator_preserves_button_and_press_release_order() {
        assert!(MouseButtonEdges::from_masks(0, 0, 0).transitions().next().is_none());
        let edges = MouseButtonEdges::from_masks(0, 0x8000_0005, 0x8000_0003);
        let received: Vec<_> = edges.transitions().map(|edge| (edge.button, edge.pressed)).collect();
        assert_eq!(received, vec![(0, true), (0, false), (1, false), (2, true), (31, true), (31, false)]);
        assert!(MouseButtonEdges::from_masks(0, 1u64 << 40, 1u64 << 40).transitions().next().is_none());
    }

    #[test]
    fn mouse_button_baseline_seeds_levels_before_ordered_transitions() {
        let edges = MouseButtonEdges::from_masks(
            (1 << 3) | (1 << 31) | (1 << 40),
            (1 << 0) | (1 << 3),
            (1 << 0) | (1 << 1) | (1 << 40),
        );
        // Button 31 was already held, 1 is about to release, 0 taps and 3
        // presses. Unsupported high bits cannot reach the native ABI.
        assert_eq!(edges.pre_transition_down_mask(), (1 << 1) | (1 << 31));
        let mut native = MouseButtonTracker::new();
        native.sync_down_mask(u64::from(edges.pre_transition_down_mask()));
        let _ = native.consume_edges();
        for edge in edges.transitions() {
            native.set_button(edge.button, edge.pressed);
        }
        assert_eq!(native.consume_edges(), MouseButtonEdges::from_masks(
            (1 << 3) | (1 << 31),
            (1 << 0) | (1 << 3),
            (1 << 0) | (1 << 1),
        ));
    }

    #[test]
    fn mouse_buttons_reports_current_state_for_all_owe_buttons() {
        let states = MouseButtons::from_mask(0b101).states();

        assert_eq!(states.len(), 32);
        assert_eq!(states[0].button, 0);
        assert!(states[0].pressed);
        assert_eq!(states[1].button, 1);
        assert!(!states[1].pressed);
        assert_eq!(states[2].button, 2);
        assert!(states[2].pressed);
    }

    #[test]
    fn mouse_button_edges_preserve_press_and_release_in_one_poll() {
        let states = MouseButtonEdges::from_masks(0, 1, 1).states();

        assert_eq!(
            &states[..2],
            &[
                MouseButtonState {
                    button: 0,
                    pressed: true,
                },
                MouseButtonState {
                    button: 0,
                    pressed: false,
                },
            ]
        );
    }

    #[test]
    fn mouse_button_tracker_exposes_tap_edges_then_clears_them() {
        let mut tracker = MouseButtonTracker::new();

        tracker.set_button(0, true);
        tracker.set_button(0, false);

        let tap = tracker.consume_edges();
        assert_eq!(tap.down().mask(), 0);
        assert_eq!(
            &tap.states()[..2],
            &[
                MouseButtonState {
                    button: 0,
                    pressed: true,
                },
                MouseButtonState {
                    button: 0,
                    pressed: false,
                },
            ]
        );

        let idle = tracker.consume_edges();
        assert_eq!(idle.down().mask(), 0);
        assert_eq!(
            idle.states().iter().filter(|state| state.pressed).count(),
            0
        );
    }

    #[test]
    fn mouse_button_tracker_level_state_reports_only_real_edges() {
        let mut tracker = MouseButtonTracker::new();

        tracker.sync_down_mask(1);
        let press = tracker.consume_edges();
        assert_eq!(press.down().mask(), 1);
        assert_eq!(
            press
                .states()
                .iter()
                .filter(|state| state.button == 0 && state.pressed)
                .count(),
            1
        );

        tracker.sync_down_mask(1);
        let held = tracker.consume_edges();
        assert_eq!(held.down().mask(), 1);
        assert!(held.transitions().next().is_none());

        tracker.sync_down_mask(0);
        let release = tracker.consume_edges();
        assert_eq!(release.down().mask(), 0);
        assert_eq!(
            release.transitions().next().unwrap(),
            MouseButtonState {
                button: 0,
                pressed: false,
            }
        );
    }

    #[test]
    fn a_button_held_while_nothing_watched_is_adopted_as_a_level_not_a_press() {
        let mut tracker = MouseButtonTracker::new();
        tracker.mark_levels_unknown();
        tracker.sync_down_mask(1);
        let held = tracker.consume_edges();
        assert_eq!(held.down().mask(), 1);
        assert!(held.transitions().next().is_none(), "no press for a button held through the gap");

        tracker.sync_down_mask(0);
        let released = tracker.consume_edges();
        assert_eq!(
            released.transitions().collect::<Vec<_>>(),
            vec![MouseButtonState { button: 0, pressed: false }],
            "its release afterwards is a real edge"
        );
    }

    /// Stands in for the window server: says whether the pointer is over
    /// another application's window and counts how often it was asked.
    #[derive(Clone, Default)]
    struct ScriptedCursor {
        over_window: Arc<AtomicBool>,
        asked: Arc<AtomicUsize>,
    }

    impl ScriptedCursor {
        fn tracker(&self) -> MouseButtonTracker {
            let (over_window, asked) = (Arc::clone(&self.over_window), Arc::clone(&self.asked));
            MouseButtonTracker::with_press_test(Box::new(move || {
                asked.fetch_add(1, Ordering::SeqCst);
                !over_window.load(Ordering::SeqCst)
            }))
        }

        fn move_over_window(&self, over: bool) {
            self.over_window.store(over, Ordering::SeqCst);
        }

        fn asked(&self) -> usize {
            self.asked.load(Ordering::SeqCst)
        }
    }

    fn transitions(edges: MouseButtonEdges) -> Vec<(u32, bool)> {
        edges.transitions().map(|edge| (edge.button, edge.pressed)).collect()
    }

    #[test]
    fn a_press_over_another_window_reaches_no_wallpaper_and_neither_does_its_release() {
        let cursor = ScriptedCursor::default();
        let mut tracker = cursor.tracker();
        cursor.move_over_window(true);
        tracker.set_button(0, true);
        let held = tracker.consume_edges();
        assert_eq!(held.down().mask(), 0, "its level is hidden too");
        assert!(transitions(held).is_empty());

        // Dragged onto the desktop and let go there: still the same gesture.
        cursor.move_over_window(false);
        tracker.set_button(0, false);
        assert!(transitions(tracker.consume_edges()).is_empty());

        tracker.set_button(0, true);
        tracker.set_button(0, false);
        assert_eq!(transitions(tracker.consume_edges()), vec![(0, true), (0, false)]);
        assert_eq!(cursor.asked(), 2, "asked once per press, never for a release");
    }

    #[test]
    fn a_press_first_seen_by_a_sample_is_judged_once_and_stays_hidden_while_held() {
        let cursor = ScriptedCursor::default();
        let mut tracker = cursor.tracker();
        cursor.move_over_window(true);
        for _ in 0..3 {
            tracker.sync_down_mask(1);
            let held = tracker.consume_edges();
            assert_eq!(held.down().mask(), 0);
            assert!(transitions(held).is_empty());
        }
        // The monitor's event for the same press arrives after the sample.
        tracker.set_button(0, true);
        cursor.move_over_window(false);
        tracker.sync_down_mask(0);
        assert!(transitions(tracker.consume_edges()).is_empty());
        assert_eq!(cursor.asked(), 1, "held samples and the late event ask nothing");
    }

    #[test]
    fn a_press_the_wallpapers_received_is_released_wherever_the_pointer_ends() {
        let cursor = ScriptedCursor::default();
        let mut tracker = cursor.tracker();
        tracker.set_button(0, true);
        assert_eq!(transitions(tracker.consume_edges()), vec![(0, true)]);

        // Held into an application window, where a second button goes down.
        cursor.move_over_window(true);
        tracker.sync_down_mask(0b11);
        let held = tracker.consume_edges();
        assert_eq!(held.down().mask(), 1, "the delivered press stays held");
        assert!(transitions(held).is_empty());

        tracker.set_button(0, false);
        tracker.set_button(1, false);
        assert_eq!(transitions(tracker.consume_edges()), vec![(0, false)]);
        assert_eq!(cursor.asked(), 2);
    }

    #[test]
    fn a_desktop_tap_and_a_window_press_in_one_sample_deliver_only_the_tap() {
        let cursor = ScriptedCursor::default();
        let mut tracker = cursor.tracker();
        tracker.set_button(0, true);
        tracker.set_button(0, false);
        cursor.move_over_window(true);
        tracker.set_button(0, true);
        let edges = tracker.consume_edges();
        assert_eq!(transitions(edges), vec![(0, true), (0, false)]);
        assert_eq!(edges.down().mask(), 0);
        assert_eq!(edges.pre_transition_down_mask(), 0, "no baseline holds the hidden press");

        tracker.set_button(0, false);
        assert!(transitions(tracker.consume_edges()).is_empty());
    }

    #[test]
    fn a_button_held_through_the_gap_is_adopted_only_over_the_desktop() {
        let cursor = ScriptedCursor::default();
        let mut tracker = cursor.tracker();
        cursor.move_over_window(true);
        tracker.mark_levels_unknown();
        tracker.sync_down_mask(1);
        assert_eq!(tracker.consume_edges().down().mask(), 0);
        tracker.sync_down_mask(0);
        assert!(transitions(tracker.consume_edges()).is_empty());

        cursor.move_over_window(false);
        tracker.mark_levels_unknown();
        tracker.sync_down_mask(1);
        let adopted = tracker.consume_edges();
        assert_eq!(adopted.down().mask(), 1);
        assert!(transitions(adopted).is_empty(), "a level, not a press");
        tracker.sync_down_mask(0);
        assert_eq!(transitions(tracker.consume_edges()), vec![(0, false)]);
        assert_eq!(cursor.asked(), 2);
    }

    #[test]
    fn a_press_seen_before_the_gap_keeps_its_verdict_through_it() {
        let cursor = ScriptedCursor::default();
        let mut tracker = cursor.tracker();
        tracker.set_button(0, true);
        cursor.move_over_window(true);
        tracker.set_button(1, true);
        let _ = tracker.consume_edges();

        // Held while no monitor watched; the pointer is over a window when they return.
        tracker.mark_levels_unknown();
        tracker.set_button(1, false);
        tracker.sync_down_mask(1);
        let held = tracker.consume_edges();
        assert_eq!(held.down().mask(), 1, "the delivered press is still held");
        assert!(transitions(held).is_empty(), "the withheld press has no release");
        tracker.sync_down_mask(0);
        assert_eq!(transitions(tracker.consume_edges()), vec![(0, false)]);
        assert_eq!(cursor.asked(), 2, "nothing is judged again");
    }

    #[test]
    fn only_windows_stacked_beneath_application_windows_count_as_the_desktop() {
        let level = |key| i64::from(CGWindowLevelForKey(key));
        for key in [CGWindowLevelKey::DesktopWindowLevelKey, CGWindowLevelKey::DesktopIconWindowLevelKey] {
            assert!(window_counts_as_desktop(42, |_| Some(level(key))));
        }
        for key in [
            CGWindowLevelKey::NormalWindowLevelKey,
            CGWindowLevelKey::FloatingWindowLevelKey,
            CGWindowLevelKey::DockWindowLevelKey,
            CGWindowLevelKey::MainMenuWindowLevelKey,
        ] {
            assert!(!window_counts_as_desktop(42, |_| Some(level(key))));
        }
        assert!(window_counts_as_desktop(0, |_| panic!("no window to look up")));
        assert!(window_counts_as_desktop(42, |_| None), "a window gone before its layer was read");
    }

    #[test]
    fn normalized_mouse_position_converts_appkit_points_to_owe_coordinates() {
        let position = NormalizedMousePosition::from_window_point(480.0, 270.0, 1920.0, 1080.0)
            .expect("valid point should normalize");

        assert_eq!(position, NormalizedMousePosition { x: 0.25, y: 0.75 });
    }

    #[test]
    fn normalized_mouse_position_clamps_and_rejects_invalid_geometry() {
        assert_eq!(
            NormalizedMousePosition::from_window_point(-10.0, 1200.0, 1920.0, 1080.0),
            Some(NormalizedMousePosition { x: 0.0, y: 0.0 })
        );
        assert_eq!(
            NormalizedMousePosition::from_window_point(f64::NAN, 0.0, 1920.0, 1080.0),
            None
        );
        assert_eq!(
            NormalizedMousePosition::from_window_point(0.0, 0.0, 0.0, 1080.0),
            None
        );
    }
}
