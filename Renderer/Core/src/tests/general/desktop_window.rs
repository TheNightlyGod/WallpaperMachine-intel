//! The AppKit wallpaper window, against a real display.
//!
//! Opening a window is a desktop action, so these cases run only when
//! `WE_RUN_MACOS_WINDOW_TESTS` is set and the test thread is the AppKit main
//! thread. Otherwise each prints a skip line and passes. The primary-display
//! sanity case needs only a display, not the opt-in.

use std::{
    ptr::NonNull,
    sync::{Arc, Mutex},
};

use block2::RcBlock;
use objc2::runtime::AnyObject;
use objc2_foundation::{
    NSNotification, NSNotificationCenter, NSNumber, NSString, NSThread, ns_string,
};

use crate::{
    DisplayDesc, EngineError, PlaceholderStyle, WallpaperWindow,
    window::{LAYER_INSTALLED_NOTIFICATION, LayerInstall},
};

const OPT_IN: &str = "WE_RUN_MACOS_WINDOW_TESTS";
const TOLERANCE: f64 = 0.001;

/// The primary display, or `None` (after saying why) when this run must not
/// or cannot open a window.
fn desktop_display(case: &str) -> Option<DisplayDesc> {
    if std::env::var_os(OPT_IN).is_none() {
        eprintln!("skipping {case}: set {OPT_IN}=1 to run the AppKit window cases");
        return None;
    }
    if !NSThread::isMainThread_class() {
        eprintln!("skipping {case}: AppKit windows need the process main thread");
        return None;
    }
    primary_display(case)
}

fn primary_display(case: &str) -> Option<DisplayDesc> {
    match DisplayDesc::primary() {
        Ok(display) => Some(display),
        Err(EngineError::Platform(message))
            if message.contains("CGMainDisplayID returned 0")
                || message.contains("no active displays") =>
        {
            eprintln!("skipping {case}: no display is available ({message})");
            None
        }
        Err(error) => panic!("{case}: the primary display could not be read: {error}"),
    }
}

/// The same display at the other scale factor, so geometry has to change.
fn rescaled(display: &DisplayDesc) -> DisplayDesc {
    let mut other = display.clone();
    other.scale_factor = if display.scale_factor > 1.0 { 1.0 } else { 2.0 };
    other
}

fn open(display: &DisplayDesc) -> WallpaperWindow {
    WallpaperWindow::builder(display.clone())
        .placeholder_style(PlaceholderStyle::default())
        .open()
        .expect("the wallpaper window should open")
}

fn geometry(window: &WallpaperWindow) -> [f64; 15] {
    let state = window.native_state_for_tests().expect("an open window reports its geometry");
    [
        state.window_x,
        state.window_y,
        state.window_width,
        state.window_height,
        state.content_view_x,
        state.content_view_y,
        state.content_view_width,
        state.content_view_height,
        state.metal_layer_x,
        state.metal_layer_y,
        state.metal_layer_width,
        state.metal_layer_height,
        state.metal_layer_contents_scale,
        state.metal_layer_drawable_width,
        state.metal_layer_drawable_height,
    ]
}

fn assert_geometry_eq(actual: &[f64; 15], expected: &[f64; 15], what: &str) {
    for (index, (actual, expected)) in actual.iter().zip(expected).enumerate() {
        assert!(
            (actual - expected).abs() <= TOLERANCE,
            "{what}: native field {index} is {actual}, expected {expected}"
        );
    }
}

fn assert_closed_error(result: Result<(), EngineError>) {
    match result {
        Err(EngineError::Platform(message)) => {
            assert_eq!(message, "wallpaper window is already closed");
        }
        other => panic!("expected the closed-window error, got {other:?}"),
    }
}

#[test]
fn the_primary_display_has_an_id_and_a_size() {
    let Some(display) = primary_display("primary display sanity") else {
        return;
    };

    assert_ne!(display.display_id, 0);
    assert_ne!(display.width, 0);
    assert_ne!(display.height, 0);
}

#[test]
fn a_window_opens_with_a_layer_and_closes_without_one() {
    let Some(display) = desktop_display("window open and close") else {
        return;
    };

    let mut window = open(&display);
    assert!(window.is_open());
    assert!(!window.metal_layer_ptr().is_null());

    window.close();
    assert!(!window.is_open());
    assert!(window.metal_layer_ptr().is_null());
}

#[test]
fn updating_the_display_reshapes_window_view_and_layer() {
    let Some(display) = desktop_display("window update_display") else {
        return;
    };
    let target = rescaled(&display);
    let scale = if target.scale_factor > 0.0 { target.scale_factor } else { 1.0 };
    let (width, height) = (f64::from(target.width) / scale, f64::from(target.height) / scale);
    let mut window = open(&display);

    window.update_display(target.clone()).unwrap();

    assert!(window.is_open());
    assert!(!window.metal_layer_ptr().is_null());
    let expected = [
        f64::from(target.x),
        f64::from(target.y),
        width,
        height,
        0.0,
        0.0,
        width,
        height,
        0.0,
        0.0,
        width,
        height,
        scale,
        f64::from(target.width),
        f64::from(target.height),
    ];
    assert_geometry_eq(&geometry(&window), &expected, "after update_display");

    window.close();
    assert_closed_error(window.update_display(display));
}

#[test]
fn reverting_a_layer_swap_restores_the_layer_and_the_geometry() {
    let Some(display) = desktop_display("window layer swap revert") else {
        return;
    };
    let mut window = open(&display);
    let original_layer = window.metal_layer_ptr();
    let original = geometry(&window);

    let swap = window.begin_layer_swap(rescaled(&display), LayerInstall::Replace).unwrap();

    assert_ne!(window.metal_layer_ptr(), original_layer);
    assert_eq!(swap.layer_ptr(), window.metal_layer_ptr());
    assert!((geometry(&window)[2] - original[2]).abs() > TOLERANCE, "the swap did not reshape the window");

    window.revert_layer_swap(swap).unwrap();

    assert!(window.is_open());
    assert_eq!(window.metal_layer_ptr(), original_layer);
    assert_geometry_eq(&geometry(&window), &original, "after the revert");
}

#[test]
fn finishing_a_layer_swap_keeps_the_new_layer() {
    let Some(display) = desktop_display("window layer swap finish") else {
        return;
    };
    let mut window = open(&display);
    let original_layer = window.metal_layer_ptr();
    let original = geometry(&window);

    let swap = window.begin_layer_swap(display, LayerInstall::Replace).unwrap();
    let new_layer = swap.layer_ptr();
    assert_ne!(new_layer, original_layer);
    swap.finish();

    assert_eq!(window.metal_layer_ptr(), new_layer);
    assert!(window.is_open());
    assert_geometry_eq(&geometry(&window), &original, "after finishing the swap");
}

/// What one layer announcement carried.
type Announcement = (usize, u32, String);

fn announcement_of(notification: &NSNotification) -> Option<Announcement> {
    let layer = notification.object()?;
    let info = notification.userInfo()?;
    let display = info.objectForKey(ns_string!("displayID"))?;
    let reason = info.objectForKey(ns_string!("reason"))?;
    let display = display.downcast_ref::<NSNumber>()?.unsignedIntValue();
    let reason = reason.downcast_ref::<NSString>()?.to_string();
    Some((objc2::rc::Retained::as_ptr(&layer) as usize, display, reason))
}

#[test]
fn every_installed_layer_is_announced_once_in_install_order() {
    let Some(display) = desktop_display("window layer announcements") else {
        return;
    };
    let heard: Arc<Mutex<Vec<Announcement>>> = Arc::default();
    let sink = Arc::clone(&heard);
    let block = RcBlock::new(move |notification: NonNull<NSNotification>| {
        // SAFETY: the center passes a live notification for the block's duration.
        if let Some(announcement) = announcement_of(unsafe { notification.as_ref() }) {
            sink.lock().unwrap().push(announcement);
        }
    });
    let center = NSNotificationCenter::defaultCenter();
    let name = NSString::from_str(LAYER_INSTALLED_NOTIFICATION);
    // SAFETY: the block only records what it is given and is called on this thread.
    let token = unsafe { center.addObserverForName_object_queue_usingBlock(Some(&name), None, None, &block) };

    let mut window = open(&display);
    let opened = window.metal_layer_ptr() as usize;
    let swap = window.begin_layer_swap(display.clone(), LayerInstall::Replace).unwrap();
    let replaced = swap.layer_ptr() as usize;
    swap.finish();
    let reconfigured = window.update_layer(display.clone()).unwrap() as usize;
    let abandoned_swap = window.begin_layer_swap(display.clone(), LayerInstall::Replace).unwrap();
    let abandoned = abandoned_swap.layer_ptr() as usize;
    window.revert_layer_swap(abandoned_swap).unwrap();
    window.close();

    // SAFETY: the token came from the `addObserver` call above.
    unsafe { center.removeObserver(AsRef::<AnyObject>::as_ref(&*token)) };

    let ours = [opened, replaced, reconfigured, abandoned];
    let heard: Vec<Announcement> = heard
        .lock()
        .unwrap()
        .iter()
        .filter(|(layer, _, _)| ours.contains(layer))
        .cloned()
        .collect();
    let id = display.display_id;
    assert_eq!(
        heard,
        vec![
            (opened, id, "open".to_owned()),
            (replaced, id, "replace".to_owned()),
            (reconfigured, id, "reconfigure".to_owned()),
            (abandoned, id, "replace".to_owned()),
        ]
    );
}

#[test]
fn the_window_cases_skip_when_the_opt_in_is_missing() {
    if std::env::var_os(OPT_IN).is_some() {
        return;
    }

    assert!(desktop_display("the opt-in gate probe").is_none());
}
