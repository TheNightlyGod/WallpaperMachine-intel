use super::{ProjectModel, PropertyKind, PropertyMetadata, PropertyValue};
use crate::{BridgeError, BridgePropertyEdit, BridgePropertyValue};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};

pub trait OverrideMapExt {
    fn to_override_json(&self) -> String;
}

impl OverrideMapExt for BTreeMap<String, PropertyValue> {
    fn to_override_json(&self) -> String {
        Value::Object(
            self.iter()
                .map(|(id, value)| (id.clone(), value.to_json()))
                .collect(),
        )
        .to_string()
    }
}

impl ProjectModel {
    pub fn override_values(
        &self,
        values: &BTreeMap<String, Value>,
    ) -> BTreeMap<String, PropertyValue> {
        values
            .iter()
            .map(|(id, raw)| {
                let value = self
                    .properties
                    .iter()
                    .find(|property| property.id == *id)
                    .map_or_else(
                        || PropertyValue::from_json(raw),
                        |property| property.value_from_json(raw),
                    );
                (id.clone(), value)
            })
            .collect()
    }

    pub fn apply_edit(
        &self,
        mut values: BTreeMap<String, PropertyValue>,
        id: &str,
        new_value: PropertyValue,
    ) -> BTreeMap<String, PropertyValue> {
        if self
            .properties
            .iter()
            .find(|property| property.id == id)
            .is_some_and(|property| property.value_is_default(&new_value))
        {
            values.remove(id);
        } else {
            values.insert(id.to_owned(), new_value);
        }
        values
    }

    pub fn edit_overrides(
        &self,
        values: &mut BTreeMap<String, Value>,
        id: &str,
        new_value: PropertyValue,
    ) {
        *values = self
            .apply_edit(self.override_values(values), id, new_value)
            .into_iter()
            .map(|(id, value)| (id, value.to_json()))
            .collect();
    }

    pub fn check_edit(
        &self,
        property_id: &str,
        value: &BridgePropertyValue,
    ) -> Result<(), BridgeError> {
        let property = self
            .properties
            .iter()
            .find(|property| property.id == property_id)
            .ok_or_else(|| BridgeError::invalid_input(format!("unknown property {property_id}")))?;
        let accepted = match (&property.kind, &property.metadata, value) {
            (PropertyKind::Bool, _, BridgePropertyValue::Bool { .. }) => true,
            (
                PropertyKind::TextInput
                | PropertyKind::File
                | PropertyKind::Directory
                | PropertyKind::Texture,
                _,
                BridgePropertyValue::String { .. },
            ) => true,
            (
                PropertyKind::Slider,
                PropertyMetadata::Slider { min, max, .. },
                BridgePropertyValue::Number { value },
            ) => value.is_finite() && value >= min && value <= max,
            (
                PropertyKind::Combo,
                PropertyMetadata::Combo { options },
                BridgePropertyValue::String { value },
            ) => options.iter().any(|option| option.value == *value),
            (PropertyKind::Color, _, BridgePropertyValue::ColorRgb { red, green, blue }) => {
                [red, green, blue]
                    .into_iter()
                    .all(|value| value.is_finite() && (0.0..=1.0).contains(value))
            }
            _ => false,
        };
        if accepted {
            Ok(())
        } else {
            Err(BridgeError::invalid_input(format!(
                "invalid value for property {property_id}"
            )))
        }
    }

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

    pub fn edited_overrides(
        &self,
        values: &BTreeMap<String, Value>,
        edits: &[(String, PropertyValue)],
    ) -> BTreeMap<String, Value> {
        let mut changed = values.clone();
        for (id, value) in edits {
            self.edit_overrides(&mut changed, id, value.clone());
        }
        changed
    }

    pub fn user_asset_property_ids(&self) -> BTreeSet<String> {
        self.properties
            .iter()
            .filter(|property| {
                matches!(property.kind, PropertyKind::File | PropertyKind::Directory)
            })
            .map(|property| property.id.clone())
            .collect()
    }

    pub fn live_property_overrides(
        &self,
        committed: &BTreeMap<String, Value>,
        current: &BTreeMap<String, Value>,
    ) -> BTreeMap<String, Value> {
        let mut live = current.clone();
        for property in &self.properties {
            if matches!(
                property.kind,
                PropertyKind::File | PropertyKind::Directory | PropertyKind::Texture
            ) {
                match committed.get(&property.id) {
                    Some(value) => {
                        live.insert(property.id.clone(), value.clone());
                    }
                    None => {
                        live.remove(&property.id);
                    }
                }
            }
        }
        live
    }
}

pub fn scene_property_override_json(
    model: Option<&ProjectModel>,
    overrides: &BTreeMap<String, Value>,
) -> Option<String> {
    let mut values = BTreeMap::new();
    if let Some(model) = model {
        for property in &model.properties {
            if property.default_is_host_supplied && !overrides.contains_key(&property.id) {
                values.insert(property.id.as_str(), property.default_value().to_json());
            }
        }
    }
    for (id, value) in overrides {
        values.insert(id.as_str(), PropertyValue::from_json(value).to_json());
    }
    if values.is_empty() {
        return None;
    }
    let document: Map<String, Value> = values
        .into_iter()
        .map(|(id, value)| (id.to_owned(), value))
        .collect();
    Some(Value::Object(document).to_string())
}
