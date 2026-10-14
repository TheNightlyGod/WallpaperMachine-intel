use crate::tests::support::platform::{primary_display_or_skip, window_tests_enabled_or_skip};

#[test]
pub fn case_primary_display() {
    let Some(display) = primary_display_or_skip() else {
        return;
    };
    assert_ne!(display.display_id, 0);
    assert_ne!(display.width, 0);
    assert_ne!(display.height, 0);
}

#[test]
pub fn case_wallpaper_window() {
    if !window_tests_enabled_or_skip("window") {
        return;
    }
    let Some(display) = primary_display_or_skip() else {
        return;
    };
    let mut window = crate::WallpaperWindow::builder(display)
        .placeholder_style(crate::PlaceholderStyle::default())
        .open()
        .expect("window should open");
    assert!(window.is_open());
    assert!(!window.metal_layer_ptr().is_null());
    window.close();
    assert!(!window.is_open());
    assert!(window.metal_layer_ptr().is_null());
}

#[test]
pub fn case_wallpaper_window_update_display() {
    if !window_tests_enabled_or_skip("window update") {
        return;
    }
    let Some(display) = primary_display_or_skip() else {
        return;
    };
    let mut window = crate::WallpaperWindow::builder(display.clone())
        .placeholder_style(crate::PlaceholderStyle::default())
        .open()
        .expect("window should open");

    let updated = crate::DisplayDesc::with_identity(
        display.display_id,
        display.identity.clone(),
        display.x,
        display.y,
        display.width,
        display.height,
        if display.scale_factor > 1.0 { 1.0 } else { 2.0 },
    );
    window
        .update_display(updated.clone())
        .expect("window update should succeed");
    assert!(window.is_open());
    assert!(!window.metal_layer_ptr().is_null());

    let native_state = window
        .native_state_for_tests()
        .expect("native state should exist");
    let scale_factor = if updated.scale_factor > 0.0 {
        updated.scale_factor
    } else {
        1.0
    };
    let point_width = f64::from(updated.width) / scale_factor;
    let point_height = f64::from(updated.height) / scale_factor;
    assert_close(native_state.window_x, f64::from(updated.x));
    assert_close(native_state.window_y, f64::from(updated.y));
    assert_close(native_state.window_width, point_width);
    assert_close(native_state.window_height, point_height);
    assert_close(native_state.content_view_x, 0.0);
    assert_close(native_state.content_view_y, 0.0);
    assert_close(native_state.content_view_width, point_width);
    assert_close(native_state.content_view_height, point_height);
    assert_close(native_state.metal_layer_x, 0.0);
    assert_close(native_state.metal_layer_y, 0.0);
    assert_close(native_state.metal_layer_width, point_width);
    assert_close(native_state.metal_layer_height, point_height);
    assert_close(native_state.metal_layer_contents_scale, scale_factor);
    assert_close(
        native_state.metal_layer_drawable_width,
        f64::from(updated.width),
    );
    assert_close(
        native_state.metal_layer_drawable_height,
        f64::from(updated.height),
    );

    window.close();
    assert!(!window.is_open());
    let error = window
        .update_display(display)
        .expect_err("closed window update should fail");
    match error {
        crate::EngineError::Platform(message) => {
            assert_eq!(message, "wallpaper window is already closed");
        }
        error => panic!("expected closed window platform error, got {error:?}"),
    }
}

#[test]
pub fn case_wallpaper_window_layer_swap_revert() {
    if !window_tests_enabled_or_skip("window layer swap revert") {
        return;
    }
    let Some(display) = primary_display_or_skip() else {
        return;
    };
    let mut window = crate::WallpaperWindow::builder(display.clone())
        .placeholder_style(crate::PlaceholderStyle::default())
        .open()
        .expect("window should open");
    let original_layer = window.metal_layer_ptr();
    let original_state = window
        .native_state_for_tests()
        .expect("native state should exist");

    // A different scale factor makes the swap change the window's geometry as
    // well, so a revert that only swapped the layer back would be caught.
    let swapped = crate::DisplayDesc::with_identity(
        display.display_id,
        display.identity.clone(),
        display.x,
        display.y,
        display.width,
        display.height,
        if display.scale_factor > 1.0 { 1.0 } else { 2.0 },
    );
    let swap = window
        .begin_layer_swap(swapped, crate::window::LayerInstall::Replace)
        .expect("layer swap should begin");
    assert_ne!(window.metal_layer_ptr(), original_layer);
    assert_eq!(swap.layer_ptr(), window.metal_layer_ptr());
    let swapped_state = window
        .native_state_for_tests()
        .expect("native state should exist");
    assert!(
        (swapped_state.window_width - original_state.window_width).abs() > 0.001,
        "the swap should have reshaped the window"
    );

    window
        .revert_layer_swap(swap)
        .expect("layer swap should revert");
    assert!(window.is_open());
    assert_eq!(window.metal_layer_ptr(), original_layer);
    assert_same_geometry(
        &window
            .native_state_for_tests()
            .expect("native state should exist"),
        &original_state,
    );

    window.close();
}

#[test]
pub fn case_wallpaper_window_layer_swap_finish() {
    if !window_tests_enabled_or_skip("window layer swap finish") {
        return;
    }
    let Some(display) = primary_display_or_skip() else {
        return;
    };
    let mut window = crate::WallpaperWindow::builder(display.clone())
        .placeholder_style(crate::PlaceholderStyle::default())
        .open()
        .expect("window should open");
    let original_layer = window.metal_layer_ptr();
    let original_state = window
        .native_state_for_tests()
        .expect("native state should exist");

    let swap = window
        .begin_layer_swap(display, crate::window::LayerInstall::Replace)
        .expect("layer swap should begin");
    let new_layer = swap.layer_ptr();
    assert_ne!(new_layer, original_layer);
    swap.finish();

    assert!(window.is_open());
    assert_eq!(window.metal_layer_ptr(), new_layer);
    // Same display, so the fresh layer is shaped exactly like the one it replaced.
    assert_same_geometry(
        &window
            .native_state_for_tests()
            .expect("native state should exist"),
        &original_state,
    );
    window.close();
}

/// Every window layer is announced once, in the order it is installed, with
/// the layer as the notification's object. A reverted swap takes its layer out
/// again without announcing anything.
#[test]
pub fn case_wallpaper_window_announces_layers() {
    use std::sync::{Arc, Mutex};

    use objc2::rc::Retained;
    use objc2_foundation::{NSNotification, NSNotificationCenter, NSNumber, NSString, ns_string};

    use crate::window::{LAYER_INSTALLED_NOTIFICATION, LayerInstall};

    if !window_tests_enabled_or_skip("window layer announcement") {
        return;
    }
    let Some(display) = primary_display_or_skip() else {
        return;
    };

    let seen = Arc::new(Mutex::new(Vec::<(usize, u32, String)>::new()));
    let sink = Arc::clone(&seen);
    let block = block2::RcBlock::new(move |notification: std::ptr::NonNull<NSNotification>| {
        // SAFETY: The center hands the block a live notification.
        let notification = unsafe { notification.as_ref() };
        let (Some(layer), Some(info)) = (notification.object(), notification.userInfo()) else {
            return;
        };
        let display_id = info
            .objectForKey(ns_string!("displayID"))
            .and_then(|value| value.downcast::<NSNumber>().ok())
            .map(|number| number.as_u32());
        let reason = info
            .objectForKey(ns_string!("reason"))
            .and_then(|value| value.downcast::<NSString>().ok())
            .map(|reason| reason.to_string());
        if let (Some(display_id), Some(reason)) = (display_id, reason) {
            sink.lock()
                .unwrap()
                .push((Retained::as_ptr(&layer) as usize, display_id, reason));
        }
    });
    let center = NSNotificationCenter::defaultCenter();
    let name = NSString::from_str(LAYER_INSTALLED_NOTIFICATION);
    // SAFETY: The test runs on the main thread, so the block runs inline; the
    // token is removed below.
    let observer: Retained<objc2::runtime::AnyObject> = unsafe {
        center.addObserverForName_object_queue_usingBlock(Some(&name), None, None, &block)
    }
    .into();

    let mut window = crate::WallpaperWindow::builder(display.clone())
        .placeholder_style(crate::PlaceholderStyle::default())
        .open()
        .expect("window should open");
    let opened = window.metal_layer_ptr() as usize;

    let swap = window
        .begin_layer_swap(display.clone(), LayerInstall::Replace)
        .expect("layer swap should begin");
    let replaced = swap.layer_ptr() as usize;
    swap.finish();

    let reconfigured = window
        .update_layer(display.clone())
        .expect("layer update should succeed") as usize;

    let swap = window
        .begin_layer_swap(display.clone(), LayerInstall::Replace)
        .expect("layer swap should begin");
    let abandoned = swap.layer_ptr() as usize;
    window
        .revert_layer_swap(swap)
        .expect("layer swap should revert");
    window.close();

    // SAFETY: The token came from the `addObserver` call above.
    unsafe { center.removeObserver(&observer) };

    // Other window cases may run beside this one; only this window's layers count.
    let ours = [opened, replaced, reconfigured, abandoned];
    let announced: Vec<_> = seen
        .lock()
        .unwrap()
        .iter()
        .filter(|(layer, ..)| ours.contains(layer))
        .cloned()
        .collect();
    let expected = [
        (opened, "open"),
        (replaced, "replace"),
        (reconfigured, "reconfigure"),
        (abandoned, "replace"),
    ]
    .map(|(layer, reason)| (layer, display.display_id, reason.to_string()));
    assert_eq!(announced, expected);
}

fn assert_same_geometry(
    actual: &crate::window::WallpaperWindowNativeState,
    expected: &crate::window::WallpaperWindowNativeState,
) {
    for (actual, expected) in [
        (actual.window_x, expected.window_x),
        (actual.window_y, expected.window_y),
        (actual.window_width, expected.window_width),
        (actual.window_height, expected.window_height),
        (actual.content_view_x, expected.content_view_x),
        (actual.content_view_y, expected.content_view_y),
        (actual.content_view_width, expected.content_view_width),
        (actual.content_view_height, expected.content_view_height),
        (actual.metal_layer_x, expected.metal_layer_x),
        (actual.metal_layer_y, expected.metal_layer_y),
        (actual.metal_layer_width, expected.metal_layer_width),
        (actual.metal_layer_height, expected.metal_layer_height),
        (
            actual.metal_layer_contents_scale,
            expected.metal_layer_contents_scale,
        ),
        (
            actual.metal_layer_drawable_width,
            expected.metal_layer_drawable_width,
        ),
        (
            actual.metal_layer_drawable_height,
            expected.metal_layer_drawable_height,
        ),
    ] {
        assert_close(actual, expected);
    }
}

fn assert_close(actual: f64, expected: f64) {
    let tolerance = 0.001;
    assert!(
        (actual - expected).abs() <= tolerance,
        "expected {actual} to be within {tolerance} of {expected}"
    );
}
