use wallpaper_core::project::ScalingMode;

use crate::{
    BridgeErrorKind,
    config::{FramingCfg, MonitorRender, SerializedSelector, WallpaperConfig},
    state::drafts::WallpaperOptionsDraft,
};

#[test]
fn cancel_restores_committed_wallpaper_config() {
    let committed = WallpaperConfig::new_for("100", "scene");
    let mut draft = WallpaperOptionsDraft::from_committed(committed.clone());

    draft.set_volume(0.25).unwrap();
    assert!(draft.is_dirty(&[]));

    draft.cancel();

    assert_eq!(draft.current(), &committed);
    assert!(!draft.is_dirty(&[]));
}

fn render_of<'a>(config: &'a WallpaperConfig, selector: &SerializedSelector) -> &'a MonitorRender {
    config
        .monitors
        .iter()
        .find(|render| &render.selector == selector)
        .expect("the display has an entry")
}

#[test]
fn a_position_is_kept_in_both_copies_so_nothing_is_left_to_apply_or_cancel() {
    let mut draft = WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("100", "scene"));
    let update = draft
        .set_position_immediate(SerializedSelector::Primary, Some(0.2), Some(0.8))
        .unwrap();

    let moved = FramingCfg {
        pan_x: 0.2,
        pan_y: 0.8,
    };
    assert!(update.changed);
    assert_eq!(update.framing, moved);
    assert_eq!(update.previous, FramingCfg::default());
    assert_eq!(
        render_of(&update.config, &SerializedSelector::Primary).framing,
        moved
    );
    assert_eq!(
        render_of(draft.current(), &SerializedSelector::Primary).framing,
        moved
    );
    assert!(!draft.is_dirty(&[]));
    assert!(!draft.requires_reconcile(&[]));

    draft.cancel();

    assert_eq!(
        render_of(draft.current(), &SerializedSelector::Primary).framing,
        moved
    );
}

#[test]
fn a_position_leaves_the_displays_other_settings_alone() {
    let mut draft = WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("100", "scene"));
    let _ = draft.set_scaling_mode_immediate(SerializedSelector::Primary, ScalingMode::Fit);

    draft
        .set_position_immediate(SerializedSelector::Primary, Some(0.0), None)
        .unwrap();
    let _ = draft.set_scaling_mode_immediate(SerializedSelector::Primary, ScalingMode::Fill);

    let render = render_of(draft.current(), &SerializedSelector::Primary).clone();
    assert_eq!(render.parse_scaling_mode(), ScalingMode::Fill);
    assert_eq!(
        render.framing,
        FramingCfg {
            pan_x: 0.0,
            pan_y: 0.5
        },
        "changing the scaling mode keeps the position"
    );
    assert_eq!(draft.current().monitors.len(), 1);
}

#[test]
fn staying_where_it_is_changes_nothing_and_adds_no_entry() {
    let mut draft = WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("100", "scene"));

    for (pan_x, pan_y) in [(None, None), (Some(0.5), None), (Some(0.5), Some(0.5))] {
        let update = draft
            .set_position_immediate(SerializedSelector::Primary, pan_x, pan_y)
            .unwrap();
        assert!(!update.changed, "{pan_x:?},{pan_y:?}");
        assert_eq!(update.framing, FramingCfg::default());
        assert!(update.config.monitors.is_empty());
    }
    assert!(draft.current().monitors.is_empty());

    draft
        .set_position_immediate(SerializedSelector::Primary, Some(0.3), Some(0.7))
        .unwrap();
    let again = draft
        .set_position_immediate(SerializedSelector::Primary, Some(0.3), None)
        .unwrap();
    assert!(!again.changed);
    assert_eq!(
        again.framing,
        FramingCfg {
            pan_x: 0.3,
            pan_y: 0.7
        }
    );
}

#[test]
fn a_position_off_the_display_is_refused_before_anything_changes() {
    let mut draft = WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("100", "scene"));
    draft
        .set_position_immediate(SerializedSelector::Primary, Some(0.3), Some(0.7))
        .unwrap();
    let before = draft.current().clone();

    for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -0.001, 1.001] {
        for (pan_x, pan_y) in [(Some(bad), None), (None, Some(bad)), (Some(0.9), Some(bad))] {
            let error = draft
                .set_position_immediate(SerializedSelector::Primary, pan_x, pan_y)
                .unwrap_err();
            assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
            assert_eq!(draft.current(), &before, "{pan_x:?},{pan_y:?}");
            assert!(!draft.is_dirty(&[]));
        }
    }
}
