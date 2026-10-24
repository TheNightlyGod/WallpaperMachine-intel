use super::*;

use crate::actor::messages::InjectSceneProjectForTest;
use crate::api::lifecycle_test_support::actor;
use crate::api::operation_contract_test_support::{DraftConfigObservation, ReadDraftConfig};
use crate::api::{
    BridgeErrorKind, BridgePropertyDescriptor, BridgePropertyKind, BridgePropertyValue,
    BridgeWallpaperOptionsSnapshot,
};

async fn select_authored_scene(
    bridge: &WallpaperBridge,
    id: &str,
    title: &str,
    project_json: &str,
) -> BridgeWallpaperOptionsSnapshot {
    actor(bridge)
        .ask(InjectSceneProjectForTest {
            id: id.to_owned(),
            title: title.to_owned(),
            project_json: project_json.to_owned(),
        })
        .await
        .expect("install the authored scene through the real actor");

    let selected = bridge
        .select_wallpaper(id.to_owned())
        .await
        .expect("select the authored scene");
    assert_eq!(selected.app.selected_wallpaper_id.as_deref(), Some(id));
    let selected_options = selected
        .wallpaper_options
        .expect("selection publishes the scene's property options");
    let options = bridge
        .wallpaper_options_snapshot(id.to_owned())
        .await
        .expect("read the selected scene's actual public options");
    assert_eq!(options, selected_options);
    assert_eq!(options.wallpaper_id, id);
    assert_eq!(options.title, title);
    assert_eq!(options.kind, BridgeWallpaperKind::ProjectScene);
    assert!(options.supported);
    options
}

fn property<'a>(
    options: &'a BridgeWallpaperOptionsSnapshot,
    id: &str,
) -> &'a BridgePropertyDescriptor {
    options
        .properties
        .iter()
        .find(|property| property.id == id)
        .unwrap_or_else(|| panic!("missing authored property {id}"))
}

fn assert_fresh_defaults_are_clean(options: &BridgeWallpaperOptionsSnapshot) {
    assert!(!options.dirty, "the global options draft must remain clean");
    for property in &options.properties {
        assert!(!property.dirty, "property {} must remain clean", property.id);
        assert_eq!(
            property.value, property.default_value,
            "property {} must retain its authored default value",
            property.id
        );
    }
}

fn assert_draft_unchanged(
    before: &DraftConfigObservation,
    after: &DraftConfigObservation,
    boundary: &str,
) {
    assert_eq!(after.saved, before.saved, "{boundary}: saved draft config");
    assert_eq!(after.pending, before.pending, "{boundary}: pending draft config");
    assert_eq!(
        after.published, before.published,
        "{boundary}: published wallpaper config"
    );
    assert_eq!(after.enabled, before.enabled, "{boundary}: enabled selectors");
    assert_eq!(
        after.pending_enabled, before.pending_enabled,
        "{boundary}: pending enabled selectors"
    );
    assert_eq!(after.dirty, before.dirty, "{boundary}: global draft dirtiness");
    assert_eq!(
        after.requires_reconcile, before.requires_reconcile,
        "{boundary}: reconcile requirement"
    );
    assert!(!after.dirty, "{boundary}: the actual global draft must stay clean");
}

#[tokio::test]
async fn boolean_public_options_preserve_html_and_follow_edit_then_default_restore() {
    with_bridges(1, |_root, _paths, bridges| {
        Box::pin(async move {
            let bridge = &bridges[0];
            let id = "410873";
            let before = select_authored_scene(
                bridge,
                id,
                "Copper Lantern Clearing",
                r#"{
                    "type": "scene",
                    "title": "Copper Lantern Clearing",
                    "general": {
                        "properties": {
                            "lantern_glow": {
                                "type": "bool",
                                "text": "<strong>Lantern &amp; fern</strong><br><i>after dusk</i>",
                                "value": false
                            }
                        }
                    }
                }"#,
            )
            .await;
            assert_eq!(before.properties.len(), 1);
            assert_fresh_defaults_are_clean(&before);
            let original = property(&before, "lantern_glow");
            assert_eq!(original.kind, BridgePropertyKind::Bool);
            assert_eq!(
                original.label_html,
                "<strong>Lantern &amp; fern</strong><br><i>after dusk</i>"
            );
            assert_eq!(original.value, BridgePropertyValue::Bool { value: false });
            assert_eq!(original.default_value, BridgePropertyValue::Bool { value: false });

            let edited = bridge
                .edit_property(
                    id.to_owned(),
                    "lantern_glow".to_owned(),
                    BridgePropertyValue::Bool { value: true },
                )
                .await
                .expect("a real Boolean edit from false to true succeeds")
                .wallpaper_options;
            assert!(edited.dirty);
            let changed = property(&edited, "lantern_glow");
            assert!(changed.dirty);
            assert_eq!(changed.value, BridgePropertyValue::Bool { value: true });
            assert_eq!(changed.default_value, BridgePropertyValue::Bool { value: false });
            assert_eq!(changed.kind, original.kind);
            assert_eq!(changed.label_html, original.label_html);
            assert_eq!(
                bridge
                    .wallpaper_options_snapshot(id.to_owned())
                    .await
                    .expect("observe the actual edited Boolean"),
                edited
            );

            let restored = bridge
                .restore_property_default(id.to_owned(), "lantern_glow".to_owned())
                .await
                .expect("restore the authored false default through the real actor")
                .wallpaper_options;
            assert_fresh_defaults_are_clean(&restored);
            let defaulted = property(&restored, "lantern_glow");
            assert_eq!(defaulted.value, BridgePropertyValue::Bool { value: false });
            assert_eq!(defaulted.default_value, BridgePropertyValue::Bool { value: false });
            assert!(!defaulted.dirty);
            assert_eq!(restored, before);
            assert_eq!(
                bridge
                    .wallpaper_options_snapshot(id.to_owned())
                    .await
                    .expect("observe the actual restored Boolean"),
                before
            );
        })
    })
    .await;
}

#[tokio::test]
async fn slider_public_metadata_and_in_range_edit_retain_authored_numeric_values() {
    with_bridges(1, |_root, _paths, bridges| {
        Box::pin(async move {
            let bridge = &bridges[0];
            let id = "520964";
            let before = select_authored_scene(
                bridge,
                id,
                "Tidal Glass Steps",
                r#"{
                    "type": "scene",
                    "title": "Tidal Glass Steps",
                    "general": {
                        "properties": {
                            "tidal_spacing": {
                                "type": "slider",
                                "text": "<em>Tidal spacing</em>",
                                "value": 5.125,
                                "min": 3.5,
                                "max": 9.75,
                                "step": 0.125,
                                "precision": 3
                            }
                        }
                    }
                }"#,
            )
            .await;
            assert_eq!(before.properties.len(), 1);
            assert_fresh_defaults_are_clean(&before);
            let original = property(&before, "tidal_spacing");
            assert_eq!(original.kind, BridgePropertyKind::Slider);
            assert_eq!(original.value, BridgePropertyValue::Number { value: 5.125 });
            assert_eq!(original.default_value, BridgePropertyValue::Number { value: 5.125 });
            let metadata = original.slider.as_ref().expect("the actual slider exposes metadata");
            assert_eq!(metadata.min, 3.5);
            assert_eq!(metadata.max, 9.75);
            assert_eq!(metadata.step, 0.125);
            assert_eq!(metadata.precision, 3);

            let edited = bridge
                .edit_property(
                    id.to_owned(),
                    "tidal_spacing".to_owned(),
                    BridgePropertyValue::Number { value: 7.375 },
                )
                .await
                .expect("an authored in-range numerical edit succeeds")
                .wallpaper_options;
            assert!(edited.dirty);
            let changed = property(&edited, "tidal_spacing");
            assert!(changed.dirty);
            assert_eq!(changed.value, BridgePropertyValue::Number { value: 7.375 });
            assert_eq!(changed.default_value, BridgePropertyValue::Number { value: 5.125 });
            assert_eq!(changed.slider, original.slider);
            assert_eq!(
                bridge
                    .wallpaper_options_snapshot(id.to_owned())
                    .await
                    .expect("observe the actual edited slider"),
                edited
            );
        })
    })
    .await;
}

#[tokio::test]
async fn invalid_edits_and_unknown_restore_leave_all_clean_properties_and_draft_unchanged() {
    with_bridges(1, |_root, _paths, bridges| {
        Box::pin(async move {
            let bridge = &bridges[0];
            let id = "630257";
            let before = select_authored_scene(
                bridge,
                id,
                "Juniper Prism Terrace",
                r#"{
                    "type": "scene",
                    "title": "Juniper Prism Terrace",
                    "general": {
                        "properties": {
                            "prism_pulse": {
                                "type": "bool",
                                "text": "Prism pulse",
                                "value": false
                            },
                            "terrace_shift": {
                                "type": "slider",
                                "text": "Terrace shift",
                                "value": 0.75,
                                "min": -4.5,
                                "max": 6.25,
                                "step": 0.25,
                                "precision": 2
                            },
                            "juniper_tint": {
                                "type": "color",
                                "text": "Juniper tint",
                                "value": "0.25 0.5 0.75"
                            },
                            "facet_style": {
                                "type": "combo",
                                "text": "Facet style",
                                "value": "frosted-arc",
                                "options": [
                                    {"label": "Frosted arc", "value": "frosted-arc"},
                                    {"label": "Woven ray", "value": "woven-ray"}
                                ]
                            }
                        }
                    }
                }"#,
            )
            .await;
            assert_eq!(before.properties.len(), 4);
            assert_fresh_defaults_are_clean(&before);
            for (property_id, kind, value) in [
                (
                    "prism_pulse",
                    BridgePropertyKind::Bool,
                    BridgePropertyValue::Bool { value: false },
                ),
                (
                    "terrace_shift",
                    BridgePropertyKind::Slider,
                    BridgePropertyValue::Number { value: 0.75 },
                ),
                (
                    "juniper_tint",
                    BridgePropertyKind::Color,
                    BridgePropertyValue::ColorRgb { red: 0.25, green: 0.5, blue: 0.75 },
                ),
                (
                    "facet_style",
                    BridgePropertyKind::Combo,
                    BridgePropertyValue::String { value: "frosted-arc".to_owned() },
                ),
            ] {
                let actual = property(&before, property_id);
                assert_eq!(actual.kind, kind, "{property_id}: actual property kind");
                assert_eq!(actual.value, value, "{property_id}: actual authored value");
                assert_eq!(actual.default_value, value, "{property_id}: actual authored default");
            }
            let combo = property(&before, "facet_style");
            assert_eq!(combo.combo_options.len(), 2);
            assert_eq!(combo.combo_options[0].label, "Frosted arc");
            assert_eq!(
                combo.combo_options[0].value,
                BridgePropertyValue::String { value: "frosted-arc".to_owned() }
            );
            assert_eq!(combo.combo_options[1].label, "Woven ray");
            assert_eq!(
                combo.combo_options[1].value,
                BridgePropertyValue::String { value: "woven-ray".to_owned() }
            );

            let draft_before = actor(bridge)
                .ask(ReadDraftConfig { wallpaper_id: id.to_owned() })
                .await
                .expect("observe the real clean global draft");
            assert!(!draft_before.dirty);
            assert_eq!(draft_before.pending, draft_before.saved);
            assert!(draft_before.pending.property_overrides.is_empty());

            let mut invalid_edits = vec![
                (
                    "unknown property ID".to_owned(),
                    "unlisted_prism_property",
                    BridgePropertyValue::Bool { value: true },
                ),
                (
                    "wrong Boolean value type".to_owned(),
                    "prism_pulse",
                    BridgePropertyValue::Number { value: 1.0 },
                ),
                (
                    "NaN slider value".to_owned(),
                    "terrace_shift",
                    BridgePropertyValue::Number { value: f64::NAN },
                ),
                (
                    "positive infinite slider value".to_owned(),
                    "terrace_shift",
                    BridgePropertyValue::Number { value: f64::INFINITY },
                ),
                (
                    "negative infinite slider value".to_owned(),
                    "terrace_shift",
                    BridgePropertyValue::Number { value: f64::NEG_INFINITY },
                ),
                (
                    "slider value below authored minimum".to_owned(),
                    "terrace_shift",
                    BridgePropertyValue::Number { value: -4.75 },
                ),
                (
                    "slider value above authored maximum".to_owned(),
                    "terrace_shift",
                    BridgePropertyValue::Number { value: 6.5 },
                ),
                (
                    "combo value absent from authored options".to_owned(),
                    "facet_style",
                    BridgePropertyValue::String { value: "unlisted-violet-spiral".to_owned() },
                ),
            ];
            for (channel, index) in [("red", 0), ("green", 1), ("blue", 2)] {
                for (boundary, invalid) in [
                    ("below zero", -0.125),
                    ("above one", 1.125),
                    ("NaN", f64::NAN),
                    ("positive infinity", f64::INFINITY),
                    ("negative infinity", f64::NEG_INFINITY),
                ] {
                    let mut components = [0.25, 0.5, 0.75];
                    components[index] = invalid;
                    invalid_edits.push((
                        format!("{channel} component {boundary}"),
                        "juniper_tint",
                        BridgePropertyValue::ColorRgb {
                            red: components[0],
                            green: components[1],
                            blue: components[2],
                        },
                    ));
                }
            }

            for (boundary, property_id, value) in invalid_edits {
                let error = bridge
                    .edit_property(id.to_owned(), property_id.to_owned(), value)
                    .await
                    .expect_err("an invalid actual property edit must be rejected");
                assert_eq!(error.kind(), BridgeErrorKind::InvalidInput, "{boundary}");
                let after = bridge
                    .wallpaper_options_snapshot(id.to_owned())
                    .await
                    .expect("read all actual properties after a rejected edit");
                assert_fresh_defaults_are_clean(&after);
                assert_eq!(after, before, "{boundary}: complete public options must not mutate");
                let draft_after = actor(bridge)
                    .ask(ReadDraftConfig { wallpaper_id: id.to_owned() })
                    .await
                    .expect("read the actual draft after a rejected edit");
                assert_draft_unchanged(&draft_before, &draft_after, &boundary);
            }

            let error = bridge
                .restore_property_default(id.to_owned(), "unlisted_restore_target".to_owned())
                .await
                .expect_err("restoring an unknown actual property must be rejected");
            assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
            let after_restore = bridge
                .wallpaper_options_snapshot(id.to_owned())
                .await
                .expect("read complete public options after rejected default restoration");
            assert_fresh_defaults_are_clean(&after_restore);
            assert_eq!(after_restore, before);
            let draft_after_restore = actor(bridge)
                .ask(ReadDraftConfig { wallpaper_id: id.to_owned() })
                .await
                .expect("read the actual draft after rejected default restoration");
            assert_draft_unchanged(&draft_before, &draft_after_restore, "unknown default restoration");
        })
    })
    .await;
}
