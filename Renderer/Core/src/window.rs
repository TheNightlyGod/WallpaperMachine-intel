// Clean-room implementation from the WallpaperMachine spec r1b-core-display.md; written without access to the original source.
use objc2::{
    MainThreadMarker, MainThreadOnly, Message, define_class, msg_send, rc::Retained,
    runtime::AnyObject,
};
use objc2_app_kit::{
    NSApplication, NSBackingStoreType, NSColor, NSScreen, NSView, NSWindow,
    NSWindowAnimationBehavior, NSWindowCollectionBehavior, NSWindowStyleMask,
};
#[cfg(not(test))]
use objc2_app_kit::{NSEvent, NSEventMask};
use objc2_core_graphics::{CGWindowLevelForKey, CGWindowLevelKey};
use objc2_foundation::{
    NSDictionary, NSInteger, NSNotificationCenter, NSNumber, NSPoint, NSRect, NSSize, NSString,
    ns_string,
};
use objc2_quartz_core::{CAMetalLayer, CATransaction};

use crate::{DisplayDesc, EngineError};

define_class!(
    /// A borderless desktop-level window that keeps exactly the frame it was
    /// given, even over the menu bar or a camera housing.
    #[unsafe(super(NSWindow))]
    #[thread_kind = MainThreadOnly]
    #[name = "MWEWallpaperDesktopWindow"]
    struct WallpaperDesktopWindow;

    impl WallpaperDesktopWindow {
        // AppKit's default would shrink or move a window that overlaps the
        // menu bar; a wallpaper must cover the whole display.
        #[unsafe(method(constrainFrameRect:toScreen:))]
        fn constrain_frame_rect(&self, frame: NSRect, _screen: Option<&NSScreen>) -> NSRect {
            frame
        }
    }
);

/// Background exposed before the first frame or while a drawable is unavailable.
/// Default to black so display wake and surface recreation cannot flash white.
#[derive(Clone, Copy, Debug)]
pub struct PlaceholderStyle {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
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

/// A desktop-level wallpaper window owning one Metal content layer.
pub struct WallpaperWindow {
    native: Option<NativeWindow>,
}

/// The retained AppKit objects of an open window. Each pointer holds one
/// retain owned by this value and is dereferenced on the main thread only.
struct NativeWindow {
    window: SendPtr,
    view: SendPtr,
    /// The layer under the view, which the renderer draws into.
    layer: SendPtr,
    /// The display the window and the layer are currently shaped for.
    display: DisplayDesc,
    /// The window server's number for the window, which the host uses to
    /// find it and keep it on a desktop of its own.
    number: isize,
}

impl WallpaperDesktopWindow {
    fn new(mtm: MainThreadMarker, frame: NSRect) -> Option<Retained<Self>> {
        let this = mtm.alloc::<Self>().set_ivars(());
        // SAFETY: the designated initialiser of NSWindow with valid arguments.
        unsafe {
            msg_send![
                super(this),
                initWithContentRect: frame,
                styleMask: NSWindowStyleMask::Borderless,
                backing: NSBackingStoreType::Buffered,
                defer: false
            ]
        }
    }
}

fn closed_window_error() -> EngineError {
    EngineError::Platform("wallpaper window is already closed".to_string())
}

/// The checks every window operation makes before it touches the main thread.
fn validate_window_display(display: &DisplayDesc) -> Result<(), EngineError> {
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
    Ok(())
}

/// The window frame for a display, in AppKit points.
fn window_frame(display: &DisplayDesc) -> NSRect {
    let scale = crate::display::sanitized_scale(display.scale_factor);
    NSRect::new(
        NSPoint::new(f64::from(display.x), f64::from(display.y)),
        NSSize::new(
            f64::from(display.width) / scale,
            f64::from(display.height) / scale,
        ),
    )
}

/// The frame of the content view and of its layer: the window's size at the
/// origin.
fn content_frame(display: &DisplayDesc) -> NSRect {
    NSRect::new(NSPoint::new(0.0, 0.0), window_frame(display).size)
}

fn drawable_size(display: &DisplayDesc) -> NSSize {
    NSSize::new(f64::from(display.width), f64::from(display.height))
}

fn as_any_object(layer: &CAMetalLayer) -> &AnyObject {
    layer
}

/// Borrows an object a [`NativeWindow`] or a [`MainThread`] token retains.
///
/// # Safety
///
/// `pointer` must point at a live object of type `T` that stays alive for `'a`,
/// and the call must be on the main thread.
unsafe fn borrow<'a, T>(pointer: SendPtr) -> &'a T {
    // SAFETY: promised by the caller.
    unsafe { &*pointer.get().cast::<T>() }
}

/// Writes the geometry of `display` to the window, view and layer, touching
/// only what differs from it, inside a transaction without implicit
/// animations.
///
/// # Safety
///
/// The pointers must be a live window, its content view and a live layer, and
/// the call must be on the main thread.
unsafe fn reshape_changed(window: SendPtr, view: SendPtr, layer: SendPtr, display: &DisplayDesc) {
    // SAFETY: promised by the caller.
    let (window, view, layer) = unsafe {
        (
            borrow::<NSWindow>(window),
            borrow::<NSView>(view),
            borrow::<CAMetalLayer>(layer),
        )
    };
    let scale = crate::display::sanitized_scale(display.scale_factor);
    CATransaction::begin();
    CATransaction::setDisableActions(true);
    if window.frame() != window_frame(display) {
        window.setFrame_display(window_frame(display), false);
    }
    if view.frame() != content_frame(display) {
        view.setFrame(content_frame(display));
    }
    if layer.frame() != content_frame(display) {
        layer.setFrame(content_frame(display));
    }
    if layer.contentsScale() != scale {
        layer.setContentsScale(scale);
    }
    if layer.drawableSize() != drawable_size(display) {
        layer.setDrawableSize(drawable_size(display));
    }
    CATransaction::commit();
}

/// Builds a fresh layer for `display`, puts it under the view, shapes
/// everything to the display and announces the layer. Returns the new
/// layer, retained once for the caller.
///
/// # Safety
///
/// `window` and `view` must be a live window and its content view, and the
/// call must be on the main thread.
unsafe fn install_fresh_layer(
    window: SendPtr,
    view: SendPtr,
    display: &DisplayDesc,
    install: LayerInstall,
) -> SendPtr {
    // SAFETY: promised by the caller.
    let (window, view) = unsafe { (borrow::<NSWindow>(window), borrow::<NSView>(view)) };
    let layer = display.build_metal_layer(&PlaceholderStyle::default());
    let scale = crate::display::sanitized_scale(display.scale_factor);
    CATransaction::begin();
    CATransaction::setDisableActions(true);
    window.setFrame_display(window_frame(display), true);
    view.setFrame(content_frame(display));
    view.setLayer(Some(layer.as_ref()));
    layer.setFrame(content_frame(display));
    layer.setContentsScale(scale);
    layer.setDrawableSize(drawable_size(display));
    CATransaction::commit();
    announce_layer_installed(
        &NSNotificationCenter::defaultCenter(),
        as_any_object(&layer),
        display.display_id,
        install,
    );
    SendPtr::from_retained(layer)
}

/// Creates the native window for `display`. Main thread only.
fn open_native(display: &DisplayDesc, style: PlaceholderStyle) -> Result<NativeWindow, EngineError> {
    let mtm = MainThreadMarker::new().ok_or_else(|| {
        EngineError::Platform("wallpaper windows can only be created on the main thread".to_string())
    })?;
    NSApplication::sharedApplication(mtm).finishLaunching();

    let window = WallpaperDesktopWindow::new(mtm, window_frame(display)).ok_or_else(|| {
        EngineError::Platform("failed to create the wallpaper window".to_string())
    })?;
    let layer = display.build_metal_layer(&style);
    // SAFETY: plain configuration calls on a window this function just made.
    unsafe {
        window.setReleasedWhenClosed(false);
        window.setLevel(CGWindowLevelForKey(CGWindowLevelKey::DesktopWindowLevelKey) as isize);
        window.setCollectionBehavior(
            NSWindowCollectionBehavior::CanJoinAllSpaces
                | NSWindowCollectionBehavior::Stationary
                | NSWindowCollectionBehavior::FullScreenAuxiliary
                | NSWindowCollectionBehavior::IgnoresCycle,
        );
        window.setCanHide(false);
    }
    window.setOpaque(true);
    window.setHasShadow(false);
    window.setMovable(false);
    window.setRestorable(false);
    window.setIgnoresMouseEvents(true);
    window.setHidesOnDeactivate(false);
    window.setExcludedFromWindowsMenu(true);
    window.setAnimationBehavior(NSWindowAnimationBehavior::None);
    window.setBackgroundColor(Some(&NSColor::colorWithSRGBRed_green_blue_alpha(
        style.red, style.green, style.blue, style.alpha,
    )));

    let view = window.contentView().ok_or_else(|| {
        EngineError::Platform("the wallpaper window has no content view".to_string())
    })?;
    view.setFrame(content_frame(display));
    // A layer-hosting view: the layer is assigned before layers are enabled.
    view.setLayer(Some(layer.as_ref()));
    view.setWantsLayer(true);

    announce_layer_installed(
        &NSNotificationCenter::defaultCenter(),
        as_any_object(&layer),
        display.display_id,
        LayerInstall::Open,
    );
    window.orderFrontRegardless();
    let number = window.windowNumber();

    Ok(NativeWindow {
        window: SendPtr::from_retained(window),
        view: SendPtr::from_retained(view),
        layer: SendPtr::from_retained(layer),
        display: display.clone(),
        number,
    })
}

/// Puts `layer` back under the view as its hosted layer.
///
/// # Safety
///
/// `view` must be a live content view, and the call must be on the main thread.
unsafe fn view_layer_swap_back(view: SendPtr, layer: &CAMetalLayer) {
    // SAFETY: promised by the caller.
    let view = unsafe { borrow::<NSView>(view) };
    CATransaction::begin();
    CATransaction::setDisableActions(true);
    view.setLayer(Some(layer.as_ref()));
    CATransaction::commit();
}

impl NativeWindow {
    /// Orders the window out, closes it and drops every retain this value
    /// owned. Main thread only.
    ///
    /// # Safety
    ///
    /// Each pointer must still own the retain it was created with.
    unsafe fn tear_down(self) {
        // SAFETY: promised by the caller; each pointer came from `into_raw`.
        unsafe {
            let window = Retained::<NSWindow>::from_raw(self.window.get().cast())
                .expect("window pointer is never null");
            window.orderOut(None);
            window.close();
            drop(Retained::<NSView>::from_raw(self.view.get().cast()));
            drop(Retained::<CAMetalLayer>::from_raw(self.layer.get().cast()));
            drop(window);
        }
    }
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
                pressed: self.mask >> button & 1 != 0,
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
        let mut states = Vec::new();
        for button in 0..32_u32 {
            let bit = 1_u64 << button;
            let pressed = self.pressed.mask & bit != 0;
            let released = self.released.mask & bit != 0;
            if pressed {
                states.push(MouseButtonState { button, pressed: true });
            }
            if released {
                states.push(MouseButtonState { button, pressed: false });
            }
            if !pressed && !released {
                states.push(MouseButtonState {
                    button,
                    pressed: self.down.mask & bit != 0,
                });
            }
        }
        states
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
/// held level, nor its release. A press they did receive is always released.
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
        let bit = 1_u64 << button;
        let held = self.down & bit != 0;
        if pressed == held {
            return;
        }
        if pressed {
            self.down |= bit;
            self.press(bit);
        } else {
            self.down &= !bit;
            self.release(bit);
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
        let now = mask & u64::from(u32::MAX);
        // Buttons held now that were not held before, and the reverse.
        let fresh = now & !self.down;
        let dropped = self.down & !now;
        // One hit-test question covers every fresh button, and only when
        // there is one. Whether the fresh buttons count as presses (watched
        // levels) or are adopted (unwatched levels), the verdict is the same.
        let fresh_hidden = if fresh != 0 && !(self.press_on_desktop)() { fresh } else { 0 };
        // Edges are only real for levels somebody watched.
        let edge_gate = if std::mem::replace(&mut self.levels_unknown, false) { 0 } else { u64::MAX };

        self.pressed |= (fresh & !fresh_hidden) & edge_gate;
        self.released |= (dropped & !self.withheld) & edge_gate;
        self.withheld = (self.withheld | fresh_hidden) & now;
        self.down = now;
    }

    #[must_use]
    pub(crate) fn consume_edges(&mut self) -> MouseButtonEdges {
        let edges =
            MouseButtonEdges::from_masks(self.down & !self.withheld, self.pressed, self.released);
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
            // SAFETY: the monitor block is only called with a live event.
            global_handler(mouse_button_state_from_event(unsafe { event.as_ref() })
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
// SAFETY: The wrapper only stores the opaque tokens, and every Objective-C
// call that touches them runs on the main thread.
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
        | NSEventMask::LeftMouseDragged
        | NSEventMask::RightMouseDragged
        | NSEventMask::OtherMouseDragged
        | NSEventMask::MouseMoved
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
    use objc2_app_kit::NSEventType;
    let (button, pressed) = match event.r#type() {
        NSEventType::LeftMouseDown => (0, true),
        NSEventType::LeftMouseUp => (0, false),
        NSEventType::RightMouseDown => (1, true),
        NSEventType::RightMouseUp => (1, false),
        NSEventType::OtherMouseDown => (u32::try_from(event.buttonNumber()).ok()?, true),
        NSEventType::OtherMouseUp => (u32::try_from(event.buttonNumber()).ok()?, false),
        _ => return None,
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
        if ![x, y, width, height].iter().all(|value| value.is_finite()) || width <= 0.0 || height <= 0.0
        {
            return None;
        }
        Some(Self {
            x: (x / width).clamp(0.0, 1.0),
            y: (1.0 - y / height).clamp(0.0, 1.0),
        })
    }
}

impl WallpaperWindow {
    #[must_use]
    pub fn builder(display: DisplayDesc) -> WallpaperWindowBuilder {
        WallpaperWindowBuilder {
            display,
            style: PlaceholderStyle::default(),
        }
    }

    pub fn close(&mut self) {
        let Some(native) = self.native.take() else {
            return;
        };
        // SAFETY: `native` still owns its retains and is torn down once.
        MainThread::dispatch(move || unsafe { native.tear_down() });
    }

    /// Moves and re-fits the open window to `display`.
    ///
    /// # Errors
    ///
    /// `InvalidInput` for a zero display id or size, `Platform` once closed.
    pub fn update_display(&mut self, display: DisplayDesc) -> Result<(), EngineError> {
        validate_window_display(&display)?;
        let native = self.native.as_mut().ok_or_else(closed_window_error)?;
        let (window, view, layer) = (native.window, native.view, native.layer);
        let target = display.clone();
        // SAFETY: the pointers are the open window's own objects.
        MainThread::dispatch(move || unsafe { reshape_changed(window, view, layer, &target) });
        native.display = display;
        Ok(())
    }

    #[must_use]
    pub fn is_open(&self) -> bool {
        self.native.is_some()
    }

    /// The window server's number for the open window; `None` once closed.
    #[must_use]
    pub fn window_number(&self) -> Option<isize> {
        self.native.as_ref().map(|native| native.number)
    }

    /// Replaces the layer under the existing view with a fresh one for
    /// `display` and returns the new layer's raw pointer. The replaced layer
    /// is released at once, so this cannot be undone; a caller that may have
    /// to put it back uses `begin_layer_swap`. The new layer is announced with
    /// [`LAYER_INSTALLED_NOTIFICATION`] as a `reconfigure`.
    ///
    /// # Errors
    ///
    /// Fails exactly when [`Self::begin_layer_swap`] does.
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
    /// `InvalidInput` for a zero display id or size, `Platform` once closed.
    pub(crate) fn begin_layer_swap(
        &mut self,
        display: DisplayDesc,
        install: LayerInstall,
    ) -> Result<LayerSwap, EngineError> {
        validate_window_display(&display)?;
        let native = self.native.as_mut().ok_or_else(closed_window_error)?;
        let (window, view) = (native.window, native.view);
        let target = display.clone();
        // SAFETY: the pointers are the open window's own objects.
        let layer = MainThread::dispatch(move || unsafe {
            install_fresh_layer(window, view, &target, install)
        });
        let previous = MainThread::own(native.layer);
        let previous_display = std::mem::replace(&mut native.display, display);
        native.layer = layer;
        Ok(LayerSwap {
            layer,
            previous,
            previous_display,
        })
    }

    /// Undoes [`Self::begin_layer_swap`]: puts the previous layer back under
    /// the view with the geometry of the display it was installed for and
    /// releases the layer that replaced it. Call it only after whatever was
    /// opened on the new layer is closed.
    ///
    /// # Errors
    ///
    /// `Platform` when the window was closed meanwhile.
    #[allow(clippy::single_call_fn)]
    pub(crate) fn revert_layer_swap(&mut self, swap: LayerSwap) -> Result<(), EngineError> {
        let LayerSwap {
            previous,
            previous_display,
            ..
        } = swap;
        let Some(native) = self.native.as_mut() else {
            // SAFETY: the token owns the retain on the previous layer.
            MainThread::dispatch(move || unsafe { previous.release() });
            return Err(closed_window_error());
        };
        let (window, view, abandoned) = (native.window, native.view, native.layer);
        let restored = previous.into_ptr();
        let target = previous_display.clone();
        // SAFETY: the pointers are live objects of this window; the abandoned
        // layer's retain is the window's own and is dropped exactly once.
        MainThread::dispatch(move || unsafe {
            let previous_layer = borrow::<CAMetalLayer>(restored);
            view_layer_swap_back(view, previous_layer);
            reshape_changed(window, view, restored, &target);
            drop(Retained::<CAMetalLayer>::from_raw(abandoned.get().cast()));
        });
        native.layer = restored;
        native.display = previous_display;
        Ok(())
    }

    /// The raw pointer of the layer the renderer draws into; null when the
    /// window is closed.
    #[must_use]
    pub fn metal_layer_ptr(&self) -> *mut std::ffi::c_void {
        self.native
            .as_ref()
            .map_or(std::ptr::null_mut(), |native| native.layer.get())
    }

    /// Reads back the native geometry; only the desktop test cases call it.
    ///
    /// # Errors
    ///
    /// `Platform` when the window is closed.
    #[cfg(test)]
    pub fn native_state_for_tests(&self) -> Result<WallpaperWindowNativeState, EngineError> {
        let native = self.native.as_ref().ok_or_else(closed_window_error)?;
        let (window, view, layer) = (native.window, native.view, native.layer);
        // SAFETY: the pointers are the open window's own objects.
        Ok(MainThread::dispatch(move || unsafe {
            let (window, view, layer) = (
                borrow::<NSWindow>(window),
                borrow::<NSView>(view),
                borrow::<CAMetalLayer>(layer),
            );
            let (window_frame, view_frame, layer_frame) =
                (window.frame(), view.frame(), layer.frame());
            let drawable = layer.drawableSize();
            WallpaperWindowNativeState {
                window_x: window_frame.origin.x,
                window_y: window_frame.origin.y,
                window_width: window_frame.size.width,
                window_height: window_frame.size.height,
                content_view_x: view_frame.origin.x,
                content_view_y: view_frame.origin.y,
                content_view_width: view_frame.size.width,
                content_view_height: view_frame.size.height,
                metal_layer_x: layer_frame.origin.x,
                metal_layer_y: layer_frame.origin.y,
                metal_layer_width: layer_frame.size.width,
                metal_layer_height: layer_frame.size.height,
                metal_layer_contents_scale: layer.contentsScale(),
                metal_layer_drawable_width: drawable.width,
                metal_layer_drawable_height: drawable.height,
            }
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

/// Collects what a wallpaper window needs before it is opened.
pub struct WallpaperWindowBuilder {
    display: DisplayDesc,
    style: PlaceholderStyle,
}

impl WallpaperWindowBuilder {
    #[must_use]
    pub fn placeholder_style(self, style: PlaceholderStyle) -> Self {
        Self { style, ..self }
    }

    /// Creates and shows the native window.
    ///
    /// # Errors
    ///
    /// `InvalidInput` for a zero display id or size, `Platform` when the
    /// window cannot be created.
    pub fn open(self) -> Result<WallpaperWindow, EngineError> {
        validate_window_display(&self.display)?;
        let Self { display, style } = self;
        let native = MainThread::dispatch(move || open_native(&display, style))?;
        Ok(WallpaperWindow {
            native: Some(native),
        })
    }
}

/// A raw pointer that may cross threads; it is only dereferenced on the main
/// thread.
#[derive(Clone, Copy)]
struct SendPtr(*mut std::ffi::c_void);
unsafe impl Send for SendPtr {}

impl SendPtr {
    /// Reads the pointer through a method so a closure captures the whole
    /// (sendable) wrapper rather than its raw field.
    fn get(self) -> *mut std::ffi::c_void {
        self.0
    }

    /// Takes over the retain `object` holds.
    fn from_retained<T: Message>(object: Retained<T>) -> Self {
        Self(Retained::into_raw(object).cast())
    }
}

/// An owned Objective-C object token that is retained and released on the
/// main thread only.
pub struct MainThread(SendPtr);

impl MainThread {
    /// Takes ownership of the retain `pointer` carries.
    fn own(pointer: SendPtr) -> Self {
        Self(pointer)
    }

    /// Hands the retain back as a plain pointer without releasing it.
    fn into_ptr(self) -> SendPtr {
        self.0
    }

    /// Releases the object. Main thread only.
    unsafe fn release(self) {
        // SAFETY: the token owns one retain; the caller is on the main thread.
        drop(unsafe { Retained::<AnyObject>::from_raw(self.0.get().cast()) });
    }

    pub fn dispatch<F, R>(body: F) -> R
    where
        F: FnOnce() -> R + Send,
        R: Send,
    {
        if MainThreadMarker::new().is_some() {
            return body();
        }
        let mut outcome: Option<std::thread::Result<R>> = None;
        {
            let slot = &mut outcome;
            dispatch2::DispatchQueue::main().exec_sync(move || {
                *slot = Some(std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)));
            });
        }
        match outcome.expect("the main queue runs the body before exec_sync returns") {
            Ok(value) => value,
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

// SAFETY: The token is only ever touched by the main-thread window path.
unsafe impl Send for MainThread {}

#[cfg(test)]
mod pointer_contract;

#[cfg(test)]
mod tests {
    use super::{
        LAYER_INSTALLED_NOTIFICATION, LayerInstall, MouseButtonEdges, MouseButtonState,
        MouseButtonTracker, MouseButtons, PlaceholderStyle,
        WallpaperWindow, announce_layer_installed, content_frame, window_counts_as_desktop,
        window_frame,
    };
    use crate::{DisplayDesc, EngineError};
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

    fn closed_window() -> WallpaperWindow {
        WallpaperWindow { native: None }
    }

    #[test]
    fn window_operations_check_the_display_before_the_window_state() {
        let good = DisplayDesc::new(1, 0, 0, 1920, 1080, 2.0);
        let no_id = DisplayDesc::new(0, 0, 0, 1920, 1080, 2.0);
        let no_width = DisplayDesc::new(1, 0, 0, 0, 1080, 2.0);
        let no_height = DisplayDesc::new(1, 0, 0, 1920, 0, 2.0);

        let mut window = closed_window();
        for display in [no_id, no_width, no_height] {
            assert!(matches!(
                window.update_display(display.clone()),
                Err(EngineError::InvalidInput(_))
            ));
            let swap = window.begin_layer_swap(display.clone(), LayerInstall::Replace);
            assert!(matches!(swap, Err(EngineError::InvalidInput(_))));
            let opened = WallpaperWindow::builder(display).open();
            assert!(matches!(opened, Err(EngineError::InvalidInput(_))));
        }
        assert!(matches!(
            window.update_display(good.clone()),
            Err(EngineError::Platform(_))
        ));
        assert!(matches!(
            window.update_layer(good),
            Err(EngineError::Platform(_))
        ));
    }

    #[test]
    fn a_closed_window_has_no_layer_and_closing_again_is_harmless() {
        let mut window = closed_window();
        assert!(!window.is_open());
        assert!(window.metal_layer_ptr().is_null());
        window.close();
        window.close();
        assert!(!window.is_open());
    }

    #[test]
    fn the_default_placeholder_is_opaque_black() {
        let style = PlaceholderStyle::default();
        assert_eq!((style.red, style.green, style.blue, style.alpha), (0.0, 0.0, 0.0, 1.0));
    }

    #[test]
    fn window_frames_follow_the_display_in_points() {
        let display = DisplayDesc::new(1, -1440, 25, 2880, 1800, 2.0);
        let frame = window_frame(&display);
        assert_eq!((frame.origin.x, frame.origin.y), (-1440.0, 25.0));
        assert_eq!((frame.size.width, frame.size.height), (1440.0, 900.0));
        let unscaled = window_frame(&DisplayDesc::new(1, 0, 0, 100, 50, 0.0));
        assert_eq!((unscaled.size.width, unscaled.size.height), (100.0, 50.0));
        assert_eq!(content_frame(&display).origin.x, 0.0);
    }

    #[test]
    fn mouse_buttons_above_the_window_range_are_ignored_by_the_tracker() {
        let mut tracker = MouseButtonTracker::new();
        tracker.set_button(32, true);
        tracker.set_button(40, true);
        tracker.sync_down_mask(1 << 40);
        assert_eq!(tracker.consume_edges(), MouseButtonEdges::from_masks(0, 0, 0));
        assert_eq!(
            MouseButtonEdges::from_level_state(MouseButtons::from_mask(0b10)),
            MouseButtonEdges::from_masks(0b10, 0b10, 0)
        );
    }
}
