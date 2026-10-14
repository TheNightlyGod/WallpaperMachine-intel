//! Helpers that convert between the GUI's per-wallpaper override map
//! (`BTreeMap<String, PropertyValue>`) and the flat JSON string that
//! `SceneDesc.property_override_json` consumes.

use std::collections::{BTreeMap, BTreeSet};

use super::{ProjectModel, ProjectProperty, PropertyKind, PropertyMetadata, PropertyValue};
use crate::api::{BridgeError, BridgePropertyEdit, BridgePropertyValue};

pub trait OverrideMapExt {
    fn to_override_json(&self) -> String;
}

/// The flat property document a scene is loaded with, or shown a preview of.
///
/// One function builds both, so the document a live preview pushes to a
/// running scene is byte for byte the one a later Apply loads it with.
///
/// The scene engine parses the project file itself, so a default this host
/// supplied rather than read from that file reaches it only here. An unbound
/// transport shortcut is exactly that: the author ships it empty and the
/// button would otherwise resolve to nothing however the panel shows it. The
/// user's own `overrides` go on top, so choosing no action still means no
/// action. Ids the project does not declare are kept. `None` when there is
/// nothing to send, which a scene reads as "all authored defaults".
#[must_use]
pub fn scene_property_override_json(
    model: Option<&ProjectModel>,
    overrides: &BTreeMap<String, serde_json::Value>,
) -> Option<String> {
    let mut document = model
        .map(|model| {
            model
                .properties
                .iter()
                .filter(|property| property.default_is_host_supplied)
                .map(|property| (property.id.clone(), property.default_value.clone()))
                .collect::<BTreeMap<_, _>>()
        })
        .unwrap_or_default();
    document.extend(
        overrides
            .iter()
            .map(|(id, value)| (id.clone(), PropertyValue::from_json(value))),
    );

    (!document.is_empty()).then(|| document.to_override_json())
}

impl OverrideMapExt for BTreeMap<String, PropertyValue> {
    fn to_override_json(&self) -> String {
        let mut obj = serde_json::Map::new();

        for (key, value) in self {
            obj.insert(key.clone(), value.to_json());
        }

        serde_json::Value::Object(obj).to_string()
    }
}

impl ProjectModel {
    #[must_use]
    pub fn override_values(
        &self,
        values: &BTreeMap<String, serde_json::Value>,
    ) -> BTreeMap<String, PropertyValue> {
        values
            .iter()
            .map(|(id, value)| {
                let value = self.property(id).map_or_else(
                    || PropertyValue::from_json(value),
                    |property| property.value_from_json(value),
                );
                (id.clone(), value)
            })
            .collect()
    }

    #[must_use]
    pub fn apply_edit(
        &self,
        mut values: BTreeMap<String, PropertyValue>,
        id: &str,
        new_value: PropertyValue,
    ) -> BTreeMap<String, PropertyValue> {
        if let Some(property) = self.property(id) {
            if property.value_is_default(&new_value) {
                values.remove(id);
            } else {
                values.insert(id.to_string(), new_value);
            }
        } else {
            values.insert(id.to_string(), new_value);
        }

        values
    }

    pub fn edit_overrides(
        &self,
        values: &mut BTreeMap<String, serde_json::Value>,
        id: &str,
        new_value: PropertyValue,
    ) {
        *values = self
            .apply_edit(self.override_values(values), id, new_value)
            .into_iter()
            .map(|(id, value)| (id, value.to_json()))
            .collect();
    }

    /// Whether `value` is one the property `property_id` accepts: the checks
    /// every way of setting a property's value goes through, so a value a host
    /// only shows is held to the same rules as one it saves.
    ///
    /// # Errors
    ///
    /// Returns an invalid-input error when the project has no such property,
    /// or its kind, range or options do not accept the value.
    pub fn check_edit(
        &self,
        property_id: &str,
        value: &BridgePropertyValue,
    ) -> Result<(), BridgeError> {
        let property = self.property(property_id).ok_or_else(|| {
            BridgeError::invalid_input(format!("unknown property id {property_id}"))
        })?;
        let channel = |channel: f64| channel.is_finite() && (0.0..=1.0).contains(&channel);
        match (&property.kind, &property.metadata, value) {
            (PropertyKind::Bool, _, BridgePropertyValue::Bool { .. })
            | (
                PropertyKind::TextInput
                | PropertyKind::File
                | PropertyKind::Directory
                | PropertyKind::Texture,
                _,
                BridgePropertyValue::String { .. },
            ) => Ok(()),
            (
                PropertyKind::Slider,
                PropertyMetadata::Slider { min, max, .. },
                BridgePropertyValue::Number { value },
            ) if value.is_finite() && (*min..=*max).contains(value) => Ok(()),
            (PropertyKind::Color, _, BridgePropertyValue::ColorRgb { red, green, blue })
                if channel(*red) && channel(*green) && channel(*blue) =>
            {
                Ok(())
            }
            (
                PropertyKind::Combo,
                PropertyMetadata::Combo { options },
                BridgePropertyValue::String { value },
            ) if options.iter().any(|option| option.value == *value) => Ok(()),
            _ => Err(BridgeError::invalid_input(format!(
                "invalid value for property id {}",
                property.id
            ))),
        }
    }

    /// `edits` checked by [`Self::check_edit`] and in the form the editing
    /// functions take.
    ///
    /// # Errors
    ///
    /// Returns the first edit's refusal; none is made then.
    pub fn checked_edits(
        &self,
        edits: Vec<BridgePropertyEdit>,
    ) -> Result<Vec<(String, PropertyValue)>, BridgeError> {
        edits
            .into_iter()
            .map(|edit| {
                self.check_edit(&edit.property_id, &edit.value)?;
                Ok((edit.property_id, edit.value.into()))
            })
            .collect()
    }

    /// `values` with `edits` made to them one after another, as
    /// [`Self::edit_overrides`] makes them to a draft's. `values` itself is not
    /// changed.
    #[must_use]
    pub fn edited_overrides(
        &self,
        values: &BTreeMap<String, serde_json::Value>,
        edits: &[(String, PropertyValue)],
    ) -> BTreeMap<String, serde_json::Value> {
        let mut edited = values.clone();
        for (id, value) in edits {
            self.edit_overrides(&mut edited, id, value.clone());
        }
        edited
    }

    /// The properties whose value is a path the user picked. Each is stored
    /// beside a copy the app keeps, so it is saved the moment it is chosen
    /// instead of waiting for Apply.
    #[must_use]
    pub fn user_asset_property_ids(&self) -> BTreeSet<String> {
        self.properties
            .iter()
            .filter(|property| matches!(property.kind, PropertyKind::File | PropertyKind::Directory))
            .map(|property| property.id.clone())
            .collect()
    }

    /// The values a running scene is shown while the user is still editing:
    /// the draft's, except for the kinds that wait for Apply.
    ///
    /// A texture is read only while a scene loads, and a file or folder is
    /// saved the moment it is picked beside a copy the app keeps, so none of
    /// the three follows the draft. Each stays at its `committed` value, or at
    /// its authored default when `committed` holds none, whatever the draft
    /// says, including a draft that cleared it. Everything else, undeclared
    /// ids included, is taken from `current` as it is.
    #[must_use]
    pub fn live_property_overrides(
        &self,
        committed: &BTreeMap<String, serde_json::Value>,
        current: &BTreeMap<String, serde_json::Value>,
    ) -> BTreeMap<String, serde_json::Value> {
        let mut live = current.clone();
        for property in self
            .properties
            .iter()
            .filter(|property| waits_for_apply(&property.kind))
        {
            match committed.get(&property.id) {
                Some(value) => {
                    live.insert(property.id.clone(), value.clone());
                }
                None => {
                    live.remove(&property.id);
                }
            }
        }
        live
    }

    fn property(&self, id: &str) -> Option<&ProjectProperty> {
        self.properties.iter().find(|property| property.id == id)
    }
}

/// Kinds whose value is not shown on a running scene as it is edited.
fn waits_for_apply(kind: &PropertyKind) -> bool {
    matches!(
        kind,
        PropertyKind::Texture | PropertyKind::File | PropertyKind::Directory
    )
}

impl ProjectProperty {
    #[must_use]
    pub fn value_from_json(&self, raw: &serde_json::Value) -> PropertyValue {
        let default = self.default_value();
        match self.kind {
            PropertyKind::Slider => raw
                .as_f64()
                .or_else(|| raw.as_str().and_then(|value| value.parse().ok()))
                .filter(|value| value.is_finite())
                .map_or_else(|| default.clone(), PropertyValue::Number),
            PropertyKind::Bool => raw
                .as_bool()
                .or_else(|| {
                    raw.as_str()
                        .and_then(|value| match value.to_ascii_lowercase().as_str() {
                            "true" | "1" => Some(true),
                            "false" | "0" => Some(false),
                            _ => None,
                        })
                })
                .map_or_else(|| default.clone(), PropertyValue::Bool),
            PropertyKind::Combo
            | PropertyKind::TextInput
            | PropertyKind::File
            | PropertyKind::Directory
            | PropertyKind::Texture => {
                PropertyValue::String(PropertyValue::json_scalar_to_string(raw))
            }
            PropertyKind::Color => match PropertyValue::from_json(raw) {
                value @ PropertyValue::ColorRgb(..) => value,
                _ => default,
            },
            _ => PropertyValue::from_json(raw),
        }
    }

    #[must_use]
    pub fn default_value(&self) -> PropertyValue {
        match self.kind {
            PropertyKind::Combo
            | PropertyKind::TextInput
            | PropertyKind::File
            | PropertyKind::Directory
            | PropertyKind::Texture => {
                PropertyValue::String(self.default_value.to_property_string())
            }
            _ => self.default_value.clone(),
        }
    }

    #[must_use]
    pub fn effective_value(&self, values: &BTreeMap<String, PropertyValue>) -> PropertyValue {
        values
            .get(&self.id)
            .cloned()
            .unwrap_or_else(|| self.default_value())
    }

    /// Restore a combo's authored scalar only at the web boundary. Editor and
    /// persisted selections stay string keys, including numeric-looking
    /// strings.
    #[must_use]
    pub fn web_value(&self, value: &PropertyValue) -> serde_json::Value {
        if let PropertyMetadata::Combo { options } = &self.metadata
            && let PropertyValue::String(selection) = value
        {
            if let Some(option) = options.iter().find(|option| option.value == *selection) {
                return option.json_value.clone();
            }
            if self.value_is_default(value) {
                return self.default_value.to_json();
            }
        }
        value.to_json()
    }

    #[must_use]
    pub fn value_is_default(&self, value: &PropertyValue) -> bool {
        value.matches_with_override_semantics(&self.default_value())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{PropertyKind, PropertyMetadata};

    fn project_model_with_property(id: &str, default_value: PropertyValue) -> ProjectModel {
        ProjectModel {
            workshop_id: "1".into(),
            title: String::new(),
            description_html: String::new(),
            project_type: wallpaper_core::project::WallpaperProjectType::Unknown,
            preview_file: None,
            entry_file: None,
            properties: vec![ProjectProperty {
                id: id.into(),
                kind: PropertyKind::Bool,
                default_value,
                default_is_host_supplied: false,
                label_html: String::new(),
                order: 0.0,
                index: 0,
                condition: None,
                metadata: PropertyMetadata::Bool,
            }],
            localization: std::sync::Arc::default(),
        }
    }

    #[test]
    fn serialize_empty_is_empty_object() {
        let map = BTreeMap::new();
        assert_eq!(map.to_override_json(), "{}");
    }

    #[test]
    fn apply_edit_inserts_nondefault_value() {
        let model = project_model_with_property("enabled", PropertyValue::Bool(false));
        let map = BTreeMap::new();

        let updated = model.apply_edit(map, "enabled", PropertyValue::Bool(true));

        assert_eq!(updated.get("enabled"), Some(&PropertyValue::Bool(true)));
    }

    #[test]
    fn apply_edit_removes_default_value() {
        let model = project_model_with_property("enabled", PropertyValue::Bool(false));
        let mut map = BTreeMap::new();
        map.insert("enabled".into(), PropertyValue::Bool(true));

        let updated = model.apply_edit(map, "enabled", PropertyValue::Bool(false));

        assert!(!updated.contains_key("enabled"));
    }

    #[test]
    fn apply_edit_removes_nearly_equal_numeric_default() {
        let model = project_model_with_property("opacity", PropertyValue::Number(0.3));
        let mut map = BTreeMap::new();
        map.insert("opacity".into(), PropertyValue::Number(0.4));

        let updated = model.apply_edit(map, "opacity", PropertyValue::Number(0.3 + f64::EPSILON));

        assert!(!updated.contains_key("opacity"));
    }

    #[test]
    fn value_for_text_input_keeps_numeric_triplet_as_string() {
        let prop = ProjectProperty {
            id: "text".into(),
            kind: PropertyKind::TextInput,
            default_value: PropertyValue::String(String::new()),
            default_is_host_supplied: false,
            label_html: String::new(),
            order: 0.0,
            index: 0,
            condition: None,
            metadata: PropertyMetadata::TextInput,
        };

        assert_eq!(
            prop.value_from_json(&serde_json::json!("0.1 0.2 0.3")),
            PropertyValue::String("0.1 0.2 0.3".to_string())
        );
    }

    #[test]
    fn combo_default_coerces_triplet_color_back_to_string() {
        let prop = ProjectProperty {
            id: "combo".into(),
            kind: PropertyKind::Combo,
            default_value: PropertyValue::ColorRgb(0.1, 0.2, 0.3),
            default_is_host_supplied: false,
            label_html: String::new(),
            order: 0.0,
            index: 0,
            condition: None,
            metadata: PropertyMetadata::Combo {
                options: Vec::new(),
            },
        };

        assert_eq!(
            prop.default_value(),
            PropertyValue::String("0.1 0.2 0.3".to_string())
        );
    }

    #[test]
    fn apply_edit_removes_kind_aware_default_value() {
        let mut model =
            project_model_with_property("combo", PropertyValue::ColorRgb(0.1, 0.2, 0.3));
        model.properties[0].id = "combo".to_string();
        model.properties[0].kind = PropertyKind::Combo;
        model.properties[0].metadata = PropertyMetadata::Combo {
            options: Vec::new(),
        };

        let mut map = BTreeMap::new();
        map.insert("combo".into(), PropertyValue::String("other".to_string()));

        let updated = model.apply_edit(
            map,
            "combo",
            PropertyValue::String("0.1 0.2 0.3".to_string()),
        );

        assert!(!updated.contains_key("combo"));
    }

    #[test]
    fn effective_value_prefers_override_over_default() {
        let prop = ProjectProperty {
            id: "enabled".into(),
            kind: PropertyKind::Bool,
            default_value: PropertyValue::Bool(false),
            default_is_host_supplied: false,
            label_html: String::new(),
            order: 0.0,
            index: 0,
            condition: None,
            metadata: PropertyMetadata::Bool,
        };
        let mut map = BTreeMap::new();
        map.insert("enabled".into(), PropertyValue::Bool(true));

        assert_eq!(prop.effective_value(&map), PropertyValue::Bool(true));
    }

    #[test]
    fn effective_value_falls_back_to_default() {
        let prop = ProjectProperty {
            id: "enabled".into(),
            kind: PropertyKind::Bool,
            default_value: PropertyValue::Bool(false),
            default_is_host_supplied: false,
            label_html: String::new(),
            order: 0.0,
            index: 0,
            condition: None,
            metadata: PropertyMetadata::Bool,
        };
        let map = BTreeMap::new();

        assert_eq!(prop.effective_value(&map), PropertyValue::Bool(false));
    }

    #[test]
    fn effective_value_uses_kind_aware_default() {
        let prop = ProjectProperty {
            id: "combo".into(),
            kind: PropertyKind::Combo,
            default_value: PropertyValue::ColorRgb(0.1, 0.2, 0.3),
            default_is_host_supplied: false,
            label_html: String::new(),
            order: 0.0,
            index: 0,
            condition: None,
            metadata: PropertyMetadata::Combo {
                options: Vec::new(),
            },
        };
        let map = BTreeMap::new();

        assert_eq!(
            prop.effective_value(&map),
            PropertyValue::String("0.1 0.2 0.3".to_string())
        );
    }

    #[test]
    fn value_matches_default_uses_tolerant_numeric_comparison() {
        let prop = ProjectProperty {
            id: "opacity".into(),
            kind: PropertyKind::Slider,
            default_value: PropertyValue::Number(0.3),
            default_is_host_supplied: false,
            label_html: String::new(),
            order: 0.0,
            index: 0,
            condition: None,
            metadata: PropertyMetadata::Slider {
                min: 0.0,
                max: 1.0,
                step: 0.01,
                precision: 2,
                fraction: false,
            },
        };

        assert!(prop.value_is_default(&PropertyValue::Number(0.3 + f64::EPSILON)));
    }

    #[test]
    fn serialize_is_stable_order() {
        let mut map = BTreeMap::new();
        map.insert("zeta".into(), PropertyValue::Bool(true));
        map.insert("alpha".into(), PropertyValue::Null);

        assert_eq!(map.to_override_json(), r#"{"alpha":null,"zeta":true}"#);
    }

    #[test]
    fn serialize_uses_property_value_json_shapes() {
        let mut map = BTreeMap::new();
        map.insert("color".into(), PropertyValue::ColorRgb(0.1, 0.2, 0.3));
        map.insert("quote".into(), PropertyValue::String(r#"a"b"#.into()));
        map.insert("scale".into(), PropertyValue::Number(1.5));

        assert_eq!(
            map.to_override_json(),
            r#"{"color":"0.1 0.2 0.3","quote":"a\"b","scale":1.5}"#
        );
    }

    /// A real manifest, so the kinds and the host-supplied defaults are the
    /// ones the parser produces rather than hand-built ones.
    fn parsed_model(properties: &str) -> ProjectModel {
        ProjectModel::parse(
            "1",
            &format!(
                r#"{{"type":"scene","title":"T","general":{{"properties":{{{properties}}}}}}}"#
            ),
        )
        .expect("a valid scene manifest")
    }

    fn values(entries: &[(&str, serde_json::Value)]) -> BTreeMap<String, serde_json::Value> {
        entries
            .iter()
            .map(|(id, value)| ((*id).to_owned(), value.clone()))
            .collect()
    }

    const SHORTCUTS: &str = r#"
        "playpausebutton":{"type":"usershortcut","text":"Play","value":"","order":1},
        "nextsongbutton":{"type":"usershortcut","text":"Next","value":"","order":2},
        "secretbutton":{"type":"usershortcut","text":"Secret","value":"","order":3},
        "alpha":{"type":"slider","text":"Alpha","value":1,"min":0,"max":1,"order":4}
    "#;

    #[test]
    fn a_scene_document_is_absent_when_there_is_nothing_to_send() {
        let model = parsed_model(r#""alpha":{"type":"slider","text":"A","value":1,"order":1}"#);

        assert_eq!(
            scene_property_override_json(Some(&model), &BTreeMap::new()),
            None
        );
        assert_eq!(scene_property_override_json(None, &BTreeMap::new()), None);
    }

    #[test]
    fn a_scene_document_carries_the_defaults_the_host_supplies() {
        let model = parsed_model(SHORTCUTS);

        // Only a default the host chose goes in: an authored one is already in
        // the file the scene engine parses, and a shortcut with no suggestion
        // stays out rather than being guessed at.
        assert_eq!(
            scene_property_override_json(Some(&model), &BTreeMap::new()).as_deref(),
            Some(r#"{"nextsongbutton":"media:next","playpausebutton":"media:playpause"}"#)
        );
    }

    #[test]
    fn the_users_value_beats_a_default_the_host_supplies() {
        let model = parsed_model(SHORTCUTS);

        // Choosing no action is a value too, and an unrelated edit leaves the
        // supplied defaults alone.
        let overrides = values(&[
            ("nextsongbutton", serde_json::json!("")),
            ("alpha", serde_json::json!(0.5)),
        ]);

        assert_eq!(
            scene_property_override_json(Some(&model), &overrides).as_deref(),
            Some(r#"{"alpha":0.5,"nextsongbutton":"","playpausebutton":"media:playpause"}"#)
        );
    }

    #[test]
    fn a_scene_document_keeps_ids_the_project_does_not_declare_in_key_order() {
        let model = parsed_model(SHORTCUTS);
        let overrides = values(&[
            ("zeta", serde_json::json!(true)),
            ("stale", serde_json::json!("kept")),
            ("tint", serde_json::json!("0.1 0.2 0.3")),
        ]);

        assert_eq!(
            scene_property_override_json(Some(&model), &overrides).as_deref(),
            Some(
                r#"{"nextsongbutton":"media:next","playpausebutton":"media:playpause","stale":"kept","tint":"0.1 0.2 0.3","zeta":true}"#
            )
        );
        // Without a manifest there are no supplied defaults to add.
        assert_eq!(
            scene_property_override_json(None, &overrides).as_deref(),
            Some(r#"{"stale":"kept","tint":"0.1 0.2 0.3","zeta":true}"#)
        );
    }

    const EVERY_KIND: &str = r#"
        "flag":{"type":"bool","text":"Flag","value":false,"order":1},
        "alpha":{"type":"slider","text":"Alpha","value":1,"min":0,"max":1,"order":2},
        "tint":{"type":"color","text":"Tint","value":"1 1 1","order":3},
        "mode":{"type":"combo","text":"Mode","value":"a",
                "options":[{"label":"A","value":"a"},{"label":"B","value":"b"}],"order":4},
        "label":{"type":"textinput","text":"Label","value":"","order":5},
        "picture":{"type":"scenetexture","text":"Picture","value":"","order":6},
        "clip":{"type":"file","text":"Clip","value":"","order":7},
        "folder":{"type":"directory","text":"Folder","value":"","order":8}
    "#;

    #[test]
    fn a_live_edit_takes_the_draft_value_of_every_kind_that_can_follow_it() {
        let model = parsed_model(EVERY_KIND);
        let committed = values(&[("flag", serde_json::json!(true))]);
        let current = values(&[
            ("flag", serde_json::json!(false)),
            ("alpha", serde_json::json!(0.25)),
            ("tint", serde_json::json!("0.5 0.25 0.75")),
            ("mode", serde_json::json!("b")),
            ("label", serde_json::json!("hello")),
        ]);

        assert_eq!(model.live_property_overrides(&committed, &current), current);
    }

    #[test]
    fn a_live_edit_leaves_a_value_the_draft_restored_to_default_out() {
        let model = parsed_model(EVERY_KIND);
        let committed = values(&[
            ("alpha", serde_json::json!(0.25)),
            ("mode", serde_json::json!("b")),
        ]);
        let current = values(&[("mode", serde_json::json!("b"))]);

        assert_eq!(
            model.live_property_overrides(&committed, &current),
            values(&[("mode", serde_json::json!("b"))]),
            "a restored slider has to read as its authored default, not its saved value"
        );
    }

    #[test]
    fn a_live_edit_keeps_a_texture_a_file_and_a_folder_at_what_is_saved() {
        let model = parsed_model(EVERY_KIND);
        let committed = values(&[
            ("picture", serde_json::json!("saved.png")),
            ("clip", serde_json::json!("/saved/clip.mp4")),
            ("folder", serde_json::json!("/saved/folder")),
        ]);
        let current = values(&[
            ("picture", serde_json::json!("pending.png")),
            ("clip", serde_json::json!("/pending/clip.mp4")),
            ("folder", serde_json::json!("/pending/folder")),
            ("alpha", serde_json::json!(0.5)),
        ]);

        assert_eq!(
            model.live_property_overrides(&committed, &current),
            values(&[
                ("picture", serde_json::json!("saved.png")),
                ("clip", serde_json::json!("/saved/clip.mp4")),
                ("folder", serde_json::json!("/saved/folder")),
                ("alpha", serde_json::json!(0.5)),
            ])
        );
    }

    #[test]
    fn a_frozen_value_the_draft_removed_stays_and_one_it_only_added_stays_out() {
        let model = parsed_model(EVERY_KIND);
        // The picture was cleared in the draft; the folder was chosen in it.
        let committed = values(&[("picture", serde_json::json!("saved.png"))]);
        let current = values(&[("folder", serde_json::json!("/pending/folder"))]);

        assert_eq!(
            model.live_property_overrides(&committed, &current),
            values(&[("picture", serde_json::json!("saved.png"))])
        );
    }

    #[test]
    fn a_live_edit_follows_the_draft_for_ids_the_project_does_not_declare() {
        let model = parsed_model(EVERY_KIND);
        let committed = values(&[
            ("stale", serde_json::json!(1)),
            ("gone", serde_json::json!(2)),
        ]);
        let current = values(&[
            ("stale", serde_json::json!(3)),
            ("fresh", serde_json::json!(4)),
        ]);

        assert_eq!(model.live_property_overrides(&committed, &current), current);
    }

    #[test]
    fn what_a_preview_shows_is_what_a_later_apply_would_load_but_for_the_frozen_kinds() {
        let model = parsed_model(EVERY_KIND);
        let committed = values(&[("picture", serde_json::json!("saved.png"))]);
        let current = values(&[
            ("picture", serde_json::json!("pending.png")),
            ("alpha", serde_json::json!(0.5)),
        ]);

        let previewed = scene_property_override_json(
            Some(&model),
            &model.live_property_overrides(&committed, &current),
        );
        let applied = scene_property_override_json(Some(&model), &current);

        assert_eq!(
            previewed.as_deref(),
            Some(r#"{"alpha":0.5,"picture":"saved.png"}"#)
        );
        assert_eq!(
            applied.as_deref(),
            Some(r#"{"alpha":0.5,"picture":"pending.png"}"#)
        );
    }
}
