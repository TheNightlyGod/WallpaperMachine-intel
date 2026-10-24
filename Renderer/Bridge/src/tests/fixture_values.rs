use wallpaper_core::{
    project::{SceneHandle, SceneTemplate},
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, WallpaperAssignment,
};

pub(super) fn anonymous(
    display_id: u32,
    scale: f64,
    refresh_hz: u32,
    window_active: bool,
) -> DisplaySnapshotEntry {
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc: DisplayDesc::with_identity(
            display_id,
            DisplayIdentity::default(),
            0,
            0,
            1920,
            1080,
            scale,
        )
        .with_refresh_rate(refresh_hz),
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active,
        assignment: None,
    }
}

pub(super) fn identified(
    uuid: &str,
    display_id: u32,
    refresh_hz: u32,
) -> DisplaySnapshotEntry {
    let identity = DisplayIdentity {
        uuid: Some(uuid.to_owned()),
        vendor_id: Some(10),
        model_id: Some(display_id),
        serial_number: Some(100 + display_id),
        unit_number: Some(display_id),
        name: Some(format!("Display {uuid}")),
    };

    DisplaySnapshotEntry {
        desc: DisplayDesc::with_identity(display_id, identity.clone(), 0, 0, 1920, 1080, 2.0)
            .with_refresh_rate(refresh_hz),
        identity,
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

pub(super) fn direct_entry(
    mut base: DisplaySnapshotEntry,
    handle: u64,
    wallpaper_id: &str,
) -> DisplaySnapshotEntry {
    let template = SceneTemplate::builder(format!(
        "/workshop/content/431960/{wallpaper_id}/project.json"
    ))
    .build()
    .expect("synthetic direct-entry fixture template must build");

    base.handle = Some(SceneHandle::new(handle));
    base.accepts_pointer_input = true;
    base.paused = false;
    base.window_active = true;
    base.assignment = Some(WallpaperAssignment::Direct(template));
    base
}
