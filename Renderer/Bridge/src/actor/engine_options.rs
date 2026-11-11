//! Wallpaper Engine's per-wallpaper options as the editor sees them: which
//! options a wallpaper offers, how its rows are drawn and which edits it takes.
//!
//! Which rows exist follows `wallpaper64.exe` `sub_140104B60` and its callers
//! (`artifacts/we-parity/decompiles/H-P0-2.md`, `H-P0-3.md`): every scene and
//! every video gets the colour options, the image filter, the flip and the
//! playback rate; a scene gets the mouse-parallax switch only when its own file
//! moves the camera with the cursor. Web pages get none.

use crate::{
    api::{
        BridgeEngineOptionEdit, BridgeEngineOptionId, BridgeEngineOptionRow, BridgeEngineOptions,
        BridgeError, BridgePropertyValue, BridgeSliderMetadata, BridgeWallpaperKind,
    },
    config::{EngineOptionId, EngineOptionsCfg},
    engine::scene_traits::SceneTraits,
    project::PropertyValue,
};

/// The options `kind` offers, in the order an editor lists them; empty for a
/// web page and a wallpaper of unknown kind.
#[must_use]
pub(crate) fn offered(kind: BridgeWallpaperKind, traits: SceneTraits) -> Vec<EngineOptionId> {
    match kind {
        BridgeWallpaperKind::ProjectScene => EngineOptionId::ALL
            .into_iter()
            .filter(|option| *option != EngineOptionId::MouseParallax || traits.camera_parallax_offered)
            .collect(),
        BridgeWallpaperKind::Video => EngineOptionId::ALL
            .into_iter()
            .filter(|option| *option != EngineOptionId::MouseParallax)
            .collect(),
        BridgeWallpaperKind::Webpage | BridgeWallpaperKind::Unknown => Vec::new(),
    }
}

/// The rows of `kind` with `current` as their values, or `None` when the kind
/// has no per-wallpaper options.
#[must_use]
pub(crate) fn project(
    kind: BridgeWallpaperKind,
    current: &EngineOptionsCfg,
    traits: SceneTraits,
    image_filters: &[String],
) -> Option<BridgeEngineOptions> {
    let options = offered(kind, traits);
    if options.is_empty() {
        return None;
    }
    let defaults = EngineOptionsCfg::default();
    let rows = options
        .into_iter()
        .map(|option| {
            let value = current.get(option);
            let default_value = defaults.get(option);
            BridgeEngineOptionRow {
                id: option.into(),
                modified: value != default_value,
                value: value.into(),
                default_value: default_value.into(),
                slider: option.range().map(|(min, max)| BridgeSliderMetadata { min, max, step: 1.0, precision: 0 }),
                enabled: match option {
                    EngineOptionId::Brightness
                    | EngineOptionId::Contrast
                    | EngineOptionId::Saturation
                    | EngineOptionId::HueShift => current.color_enabled,
                    EngineOptionId::FilterStrength => !current.image_filter.is_empty(),
                    _ => true,
                },
            }
        })
        .collect();
    Some(BridgeEngineOptions { rows, image_filters: image_filters.to_vec() })
}

/// `value` as an edit of `option` for a wallpaper of `kind`.
///
/// # Errors
///
/// Refuses (`InvalidInput`) an option the wallpaper does not offer, a switch
/// given anything but a boolean, a slider given anything but a finite number
/// inside its range, and an image filter that is neither empty nor one of
/// `image_filters`.
pub(crate) fn check_edit(
    kind: BridgeWallpaperKind,
    traits: SceneTraits,
    image_filters: &[String],
    option: BridgeEngineOptionId,
    value: &BridgePropertyValue,
) -> Result<(EngineOptionId, PropertyValue), BridgeError> {
    let id = EngineOptionId::from(option);
    if !offered(kind, traits).contains(&id) {
        return Err(BridgeError::invalid_input(format!(
            "{option:?} is not a Wallpaper Engine option of this wallpaper"
        )));
    }
    let accepted = match (id, value) {
        (id, BridgePropertyValue::Bool { value }) if id.is_switch() => PropertyValue::Bool(*value),
        (EngineOptionId::ImageFilter, BridgePropertyValue::String { value }) => {
            if !value.is_empty() && !image_filters.iter().any(|name| name == value) {
                return Err(BridgeError::invalid_input(format!("unknown image filter {value}")));
            }
            PropertyValue::String(value.clone())
        }
        (id, BridgePropertyValue::Number { value }) => {
            let Some((min, max)) = id.range() else {
                return Err(BridgeError::invalid_input(format!("{option:?} does not take a number")));
            };
            if !value.is_finite() || !(min..=max).contains(value) {
                return Err(BridgeError::invalid_input(format!(
                    "{option:?} must be between {min} and {max}"
                )));
            }
            PropertyValue::Number(*value)
        }
        _ => {
            return Err(BridgeError::invalid_input(format!(
                "{option:?} does not take this kind of value"
            )));
        }
    };
    Ok((id, accepted))
}

/// Every entry of `pending` checked as [`check_edit`] checks one.
///
/// # Errors
///
/// The first refusal; nothing is made of the others then.
pub(crate) fn check_edits(
    kind: BridgeWallpaperKind,
    traits: SceneTraits,
    image_filters: &[String],
    pending: Vec<BridgeEngineOptionEdit>,
) -> Result<Vec<(EngineOptionId, PropertyValue)>, BridgeError> {
    pending
        .iter()
        .map(|edit| check_edit(kind, traits, image_filters, edit.option, &edit.value))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const OFFERED: SceneTraits = SceneTraits { camera_parallax_offered: true };

    fn ids(kind: BridgeWallpaperKind, traits: SceneTraits) -> Vec<EngineOptionId> {
        offered(kind, traits)
    }

    #[test]
    fn a_scene_offers_mouse_parallax_only_when_its_file_moves_the_camera_and_a_video_never() {
        assert!(!ids(BridgeWallpaperKind::ProjectScene, SceneTraits::default()).contains(&EngineOptionId::MouseParallax));
        assert!(ids(BridgeWallpaperKind::ProjectScene, OFFERED).contains(&EngineOptionId::MouseParallax));
        assert!(ids(BridgeWallpaperKind::ProjectScene, SceneTraits::default()).contains(&EngineOptionId::PlaybackRate));
        let video = ids(BridgeWallpaperKind::Video, OFFERED);
        assert_eq!(video.len(), 9);
        assert!(!video.contains(&EngineOptionId::MouseParallax));
        assert!(ids(BridgeWallpaperKind::Webpage, OFFERED).is_empty());
        assert!(ids(BridgeWallpaperKind::Unknown, OFFERED).is_empty());
    }

    #[test]
    fn rows_follow_the_colour_switch_and_the_chosen_filter() {
        let mut options = EngineOptionsCfg::default();
        let rows = project(BridgeWallpaperKind::Video, &options, SceneTraits::default(), &[]).unwrap().rows;
        let enabled = |rows: &[BridgeEngineOptionRow], id| rows.iter().find(|row| row.id == id).unwrap().enabled;
        assert!(!enabled(&rows, BridgeEngineOptionId::Brightness));
        assert!(!enabled(&rows, BridgeEngineOptionId::FilterStrength));
        assert!(rows.iter().all(|row| !row.modified));

        options.color_enabled = true;
        options.image_filter = "amber".into();
        let rows = project(BridgeWallpaperKind::Video, &options, SceneTraits::default(), &["amber".into()])
            .unwrap()
            .rows;
        assert!(enabled(&rows, BridgeEngineOptionId::HueShift));
        assert!(enabled(&rows, BridgeEngineOptionId::FilterStrength));
        let rate = rows.iter().find(|row| row.id == BridgeEngineOptionId::PlaybackRate).unwrap();
        assert_eq!(rate.slider, Some(BridgeSliderMetadata { min: 10.0, max: 200.0, step: 1.0, precision: 0 }));
        assert!(rows.iter().find(|row| row.id == BridgeEngineOptionId::ColorEnabled).unwrap().modified);
    }

    #[test]
    fn edits_outside_what_an_option_takes_are_refused() {
        let filters = ["amber".to_owned()];
        let check = |option, value: BridgePropertyValue| {
            check_edit(BridgeWallpaperKind::ProjectScene, SceneTraits::default(), &filters, option, &value)
        };
        assert!(check(BridgeEngineOptionId::Brightness, BridgePropertyValue::Number { value: 60.0 }).is_ok());
        assert!(check(BridgeEngineOptionId::Brightness, BridgePropertyValue::Number { value: 101.0 }).is_err());
        assert!(check(BridgeEngineOptionId::Brightness, BridgePropertyValue::Number { value: f64::NAN }).is_err());
        assert!(check(BridgeEngineOptionId::PlaybackRate, BridgePropertyValue::Number { value: 5.0 }).is_err());
        assert!(check(BridgeEngineOptionId::ColorEnabled, BridgePropertyValue::Number { value: 1.0 }).is_err());
        assert!(check(BridgeEngineOptionId::FlipHorizontal, BridgePropertyValue::Bool { value: true }).is_ok());
        assert!(check(BridgeEngineOptionId::ImageFilter, BridgePropertyValue::String { value: "amber".into() }).is_ok());
        assert!(check(BridgeEngineOptionId::ImageFilter, BridgePropertyValue::String { value: String::new() }).is_ok());
        assert!(check(BridgeEngineOptionId::ImageFilter, BridgePropertyValue::String { value: "teal".into() }).is_err());
        assert!(check(BridgeEngineOptionId::MouseParallax, BridgePropertyValue::Bool { value: false }).is_err());
        assert!(
            check_edit(
                BridgeWallpaperKind::Webpage,
                OFFERED,
                &filters,
                BridgeEngineOptionId::FlipHorizontal,
                &BridgePropertyValue::Bool { value: true }
            )
            .is_err()
        );
    }
}
