use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;

use wallpaper_core::project::ScalingMode;

use crate::{
    api::BridgeError,
    config::{
        EngineOptionId, EngineOptionsCfg, FramingCfg, MonitorRender, SerializedSelector,
        WallpaperConfig, stored_frame_rate,
    },
    project::{ProjectModel, PropertyValue, scene_property_override_json},
};

/// What moving a wallpaper on one display did to its committed config.
#[derive(Clone, Debug)]
pub struct PositionUpdate {
    /// The committed config with the new position in it.
    pub config: WallpaperConfig,
    /// Where the wallpaper sits on that display now.
    pub framing: FramingCfg,
    /// Where it was saved before, for undoing the move if saving fails.
    pub previous: FramingCfg,
    /// Whether that differs from what was saved before. A position that did
    /// not change needs neither a write nor a word with the renderer.
    pub changed: bool,
}

/// Where `config` saves the wallpaper on the display `selector` names: the
/// centre for a display nobody positioned.
#[must_use]
pub fn saved_framing(config: &WallpaperConfig, selector: &SerializedSelector) -> FramingCfg {
    config
        .monitors
        .iter()
        .find(|render| &render.selector == selector)
        .map_or_else(FramingCfg::default, |render| render.framing)
}

/// `saved` with the axes that were given; an axis left as `None` keeps its
/// saved value, so a horizontal drag never disturbs the vertical position.
///
/// # Errors
///
/// Returns an error when an axis is not a finite fraction between 0 and 1: a
/// position outside the display is a request this API refuses instead of
/// quietly moving it to an edge.
pub fn moved_framing(
    saved: FramingCfg,
    pan_x: Option<f64>,
    pan_y: Option<f64>,
) -> Result<FramingCfg, BridgeError> {
    if [pan_x, pan_y]
        .into_iter()
        .flatten()
        .any(|pan| !(0.0..=1.0).contains(&pan))
    {
        return Err(BridgeError::invalid_input(
            "position must be a fraction between 0 and 1",
        ));
    }
    Ok(FramingCfg {
        pan_x: pan_x.unwrap_or(saved.pan_x),
        pan_y: pan_y.unwrap_or(saved.pan_y),
    })
}

/// The two property documents a scene wallpaper has while it is being edited.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PropertyDocuments {
    /// What a running scene is shown: the pending edits, except the kinds that
    /// wait for Apply (see `ProjectModel::live_property_overrides`).
    pub shown: String,
    /// What the saved configuration loads a scene with, which is also what a
    /// scene falls back to when the edit is cancelled. `{}` stands for "the
    /// project's authored defaults", where a descriptor carries no document.
    pub saved: String,
}

/// The documents for a wallpaper whose saved configuration is `committed` and
/// whose pending edits are in `current`.
///
/// Both come out of `scene_property_override_json`, the builder of the
/// descriptors, so `saved` is byte for byte what a scene opened from the
/// saved configuration is loaded with, and `shown` is what Apply would load
/// but for the kinds a running scene cannot take. The two are equal exactly
/// when showing the pending edits would change nothing.
#[must_use]
pub fn property_documents(
    model: &ProjectModel,
    committed: &WallpaperConfig,
    current: &WallpaperConfig,
) -> PropertyDocuments {
    let document = |overrides: &BTreeMap<String, serde_json::Value>| {
        scene_property_override_json(Some(model), overrides).unwrap_or_else(|| "{}".to_string())
    };
    PropertyDocuments {
        shown: document(
            &model.live_property_overrides(&committed.property_overrides, &current.property_overrides),
        ),
        saved: document(&committed.property_overrides),
    }
}

#[derive(Clone, Debug)]
pub struct WallpaperOptionsDraft {
    saved_config: WallpaperConfig,
    pending_config: WallpaperConfig,
    saved_assignment: Vec<SerializedSelector>,
    pending_assignment: Vec<SerializedSelector>,
}

impl WallpaperOptionsDraft {
    #[must_use]
    pub fn from_committed(committed: WallpaperConfig) -> Self {
        Self::from_committed_with_enabled_displays(committed, Vec::new())
    }

    #[must_use]
    pub fn from_committed_with_enabled_displays(
        committed: WallpaperConfig,
        enabled_displays: Vec<SerializedSelector>,
    ) -> Self {
        Self {
            pending_config: committed.clone(),
            saved_config: committed,
            pending_assignment: enabled_displays.clone(),
            saved_assignment: enabled_displays,
        }
    }

    #[must_use]
    pub fn current(&self) -> &WallpaperConfig {
        &self.pending_config
    }

    /// What is saved, as opposed to the pending edits in [`Self::current`].
    #[must_use]
    pub fn committed(&self) -> &WallpaperConfig {
        &self.saved_config
    }

    /// The documents of this draft, for showing its property edits on a
    /// running scene.
    #[must_use]
    pub fn property_documents(&self, model: &ProjectModel) -> PropertyDocuments {
        property_documents(model, &self.saved_config, &self.pending_config)
    }

    #[must_use]
    pub fn is_dirty(&self, active_enabled_displays: &[SerializedSelector]) -> bool {
        self.pending_config != self.saved_config
            || self.assignment_discrepancy(active_enabled_displays)
    }

    #[must_use]
    pub fn requires_reconcile(&self, active_enabled_displays: &[SerializedSelector]) -> bool {
        if self.assignment_discrepancy(active_enabled_displays) {
            return true;
        }

        let saved = &self.saved_config;
        let pending = &self.pending_config;
        if pending.schema_version != saved.schema_version
            || pending.workshop_id != saved.workshop_id
            || pending.r#type != saved.r#type
            || pending.media_integration_enabled != saved.media_integration_enabled
            || pending.property_overrides != saved.property_overrides
            || pending.engine_options != saved.engine_options
            || !PartialEq::eq(&saved.audio, &saved.audio)
            || pending.monitors.len() < saved.monitors.len()
        {
            return true;
        }

        for (saved_row, pending_row) in saved.monitors.iter().zip(&pending.monitors) {
            if pending_row.selector != saved_row.selector
                || pending_row.scaling_mode != saved_row.scaling_mode
                || pending_row.frame_rate != saved_row.frame_rate
                || pending_row.framing != saved_row.framing
            {
                return true;
            }
            // Saved duplicate rows retain the first-row scale comparison, including NaN.
            let first = saved.monitors.iter().find(|row| row.selector == saved_row.selector);
            if !first.is_some_and(|row| row.scaling_factor == saved_row.scaling_factor) {
                return true;
            }
        }

        let saved_count = saved.monitors.len();
        for index in saved_count..pending.monitors.len() {
            let row = &pending.monitors[index];
            if saved.monitors.iter().any(|saved_row| saved_row.selector == row.selector)
                || pending.monitors[saved_count..index]
                    .iter()
                    .any(|previous| previous.selector == row.selector)
                || row.scaling_mode != "fill"
                || row.frame_rate.is_some()
                || row.framing != FramingCfg::default()
            {
                return true;
            }
        }
        false
    }

    pub fn set_volume(&mut self, volume: f32) -> Result<(), BridgeError> {
        Self::check_volume(volume)?;
        self.pending_config.audio.volume = volume;
        Ok(())
    }

    #[must_use]
    pub fn set_volume_immediate(&mut self, volume: f32) -> Result<WallpaperConfig, BridgeError> {
        Self::check_volume(volume)?;
        self.saved_config.audio.volume = volume;
        self.pending_config.audio.volume = volume;
        Ok(self.saved_config.clone())
    }

    pub fn set_muted(&mut self, muted: bool) {
        self.pending_config.audio.muted = muted;
    }

    #[must_use]
    pub fn set_muted_immediate(&mut self, muted: bool) -> WallpaperConfig {
        self.saved_config.audio.muted = muted;
        self.pending_config.audio.muted = muted;
        self.saved_config.clone()
    }

    pub fn set_audio_response_enabled(&mut self, enabled: bool) {
        self.pending_config.audio.response_enabled = enabled;
    }

    #[must_use]
    pub fn set_audio_response_enabled_immediate(&mut self, enabled: bool) -> WallpaperConfig {
        self.saved_config.audio.response_enabled = enabled;
        self.pending_config.audio.response_enabled = enabled;
        self.saved_config.clone()
    }

    /// Media integration is applied immediately, like audio response: it is a
    /// switch the user flips, not an option staged behind Apply.
    #[must_use]
    pub fn set_media_integration_enabled_immediate(&mut self, enabled: bool) -> WallpaperConfig {
        self.pending_config.media_integration_enabled = enabled;
        self.saved_config.media_integration_enabled = enabled;
        self.saved_config.clone()
    }

    /// Stores or clears a file or directory property's path immediately.
    ///
    /// The host has already staged the file and decided what the page must be
    /// given, so the value is persisted exactly as handed over and reaches the
    /// page on the next `applyUserProperties` instead of waiting behind Apply.
    /// Clearing writes the property's own default back, which for these kinds
    /// is the empty string the page reads as "nothing chosen".
    #[must_use]
    pub fn set_property_path_immediate(
        &mut self,
        model: &ProjectModel,
        id: &str,
        path: Option<String>,
    ) -> WallpaperConfig {
        let value = PropertyValue::String(path.unwrap_or_default());
        model.edit_overrides(&mut self.pending_config.property_overrides, id, value.clone());
        model.edit_overrides(&mut self.saved_config.property_overrides, id, value);
        self.saved_config.clone()
    }

    pub fn set_display_enabled(
        &mut self,
        selector: SerializedSelector,
        enabled: bool,
        active_enabled_displays: &[SerializedSelector],
    ) {
        self.set_display_aliases_enabled(
            std::slice::from_ref(&selector),
            enabled,
            active_enabled_displays,
        );
    }

    pub fn set_display_aliases_enabled(
        &mut self,
        selectors: &[SerializedSelector],
        enabled: bool,
        active_enabled_displays: &[SerializedSelector],
    ) {
        if !self.assignment_intent_changed() {
            active_enabled_displays.clone_into(&mut self.saved_assignment);
            active_enabled_displays.clone_into(&mut self.pending_assignment);
        }
        if enabled {
            for selector in selectors {
                if !self.pending_assignment.contains(selector) {
                    self.pending_assignment.push(selector.clone());
                }
            }
        } else {
            self.pending_assignment.retain(|selector| !selectors.contains(selector));
        }
    }

    #[must_use]
    pub fn display_enabled(&self, selector: &SerializedSelector) -> bool {
        self.pending_assignment.contains(selector)
    }

    #[must_use]
    pub fn display_dirty(
        &self,
        selector: &SerializedSelector,
        active_enabled_displays: &[SerializedSelector],
    ) -> bool {
        self.assignment_intent_changed()
            && self.pending_assignment.contains(selector) != active_enabled_displays.contains(selector)
    }

    #[must_use]
    pub fn enabled_displays(&self) -> &[SerializedSelector] {
        &self.pending_assignment
    }

    pub fn rebase_enabled_displays(&mut self, enabled_displays: Vec<SerializedSelector>) {
        self.saved_assignment.clone_from(&enabled_displays);
        self.pending_assignment = enabled_displays;
    }

    #[must_use]
    pub fn effective_display_enabled(
        &self,
        selector: &SerializedSelector,
        active_enabled_displays: &[SerializedSelector],
    ) -> bool {
        if self.assignment_intent_changed() {
            self.pending_assignment.contains(selector)
        } else {
            active_enabled_displays.contains(selector)
        }
    }

    #[must_use]
    pub fn effective_enabled_displays(
        &self,
        active_enabled_displays: &[SerializedSelector],
    ) -> Vec<SerializedSelector> {
        if self.assignment_intent_changed() {
            return self.pending_assignment.clone();
        }
        let mut enabled: Vec<_> = self.pending_assignment
            .iter()
            .filter(|selector| active_enabled_displays.contains(selector))
            .cloned()
            .collect();
        for selector in self.saved_assignment.iter().chain(active_enabled_displays) {
            if active_enabled_displays.contains(selector) && !enabled.contains(selector) {
                enabled.push(selector.clone());
            }
        }
        enabled
    }

    pub fn set_display_render_enabled(&mut self, selector: SerializedSelector, enabled: bool) {
        if enabled {
            Self::monitor_for_edit(&mut self.pending_config, Cow::Owned(selector));
        } else {
            self.pending_config.monitors.retain(|row| row.selector != selector);
        }
    }

    pub fn set_scaling_mode(&mut self, selector: SerializedSelector, mode: ScalingMode) {
        let row = Self::monitor_for_edit(&mut self.pending_config, Cow::Owned(selector));
        Self::store_scaling_mode(row, mode);
    }

    #[must_use]
    pub fn set_scaling_mode_immediate(
        &mut self,
        selector: SerializedSelector,
        mode: ScalingMode,
    ) -> WallpaperConfig {
        let saved_row = Self::monitor_for_edit(&mut self.saved_config, Cow::Borrowed(&selector));
        Self::store_scaling_mode(saved_row, mode);
        let pending_row = Self::monitor_for_edit(&mut self.pending_config, Cow::Owned(selector));
        Self::store_scaling_mode(pending_row, mode);
        self.saved_config.clone()
    }

    pub fn set_scaling_factor(
        &mut self,
        selector: SerializedSelector,
        factor: f64,
    ) -> Result<(), BridgeError> {
        if !factor.is_finite() || factor <= 0.0 {
            return Err(BridgeError::invalid_input("Scaling factor must be finite and positive"));
        }
        Self::monitor_for_edit(&mut self.pending_config, Cow::Owned(selector)).scaling_factor = factor;
        Ok(())
    }

    /// Moves the wallpaper on one display and saves the move at once.
    ///
    /// A position is the drag editor's answer, and it has to still be there when
    /// the pointer is released, so it is committed like the scaling mode and
    /// not held behind Apply like the scale factor: both copies change, which
    /// leaves nothing for Cancel to undo and nothing for Apply to reopen.
    ///
    /// An axis left as `None` keeps its saved value, so a horizontal drag never
    /// disturbs the vertical position. A position equal to the saved one is not
    /// a change, and a display nobody ever positioned gains no entry from being
    /// told to stay centred.
    ///
    /// # Errors
    ///
    /// Returns an error when an axis is not a finite fraction between 0 and 1.
    /// The wallpaper is left exactly as it was: a position outside the display
    /// is a request this API refuses instead of quietly moving it to an edge.
    pub fn set_position_immediate(
        &mut self,
        selector: SerializedSelector,
        pan_x: Option<f64>,
        pan_y: Option<f64>,
    ) -> Result<PositionUpdate, BridgeError> {
        let saved = saved_framing(&self.saved_config, &selector);
        let framing = moved_framing(saved, pan_x, pan_y)?;
        if framing == saved {
            return Ok(PositionUpdate {
                config: self.saved_config.clone(),
                framing,
                previous: saved,
                changed: false,
            });
        }

        Self::monitor_for_edit(&mut self.saved_config, Cow::Borrowed(&selector)).framing = framing;
        Self::monitor_for_edit(&mut self.pending_config, Cow::Owned(selector)).framing = framing;
        Ok(PositionUpdate {
            config: self.saved_config.clone(),
            framing,
            previous: saved,
            changed: true,
        })
    }

    pub fn set_target_fps(&mut self, selector: SerializedSelector, fps: u32, max_fps: u32) {
        Self::monitor_for_edit(&mut self.pending_config, Cow::Owned(selector)).frame_rate =
            stored_frame_rate(fps, max_fps);
    }

    #[must_use]
    pub fn set_target_fps_immediate(
        &mut self,
        selector: SerializedSelector,
        fps: u32,
        max_fps: u32,
    ) -> WallpaperConfig {
        let rate = stored_frame_rate(fps, max_fps);
        Self::monitor_for_edit(&mut self.saved_config, Cow::Borrowed(&selector)).frame_rate = rate;
        Self::monitor_for_edit(&mut self.pending_config, Cow::Owned(selector)).frame_rate = rate;
        self.saved_config.clone()
    }

    pub fn edit_property(&mut self, model: &ProjectModel, id: &str, value: PropertyValue) {
        model.edit_overrides(&mut self.pending_config.property_overrides, id, value);
    }

    /// This draft with `edits` made to it one after another, as
    /// [`Self::edit_property`] makes them, and this draft left as it is.
    ///
    /// It is how a value that is only being shown, a slider still being
    /// dragged, reaches a preview without becoming an edit: nothing is dirty,
    /// saved or announced by it.
    #[must_use]
    pub fn with_edits(&self, model: &ProjectModel, edits: &[(String, PropertyValue)]) -> Self {
        let mut edited = self.clone();
        edited.pending_config.property_overrides =
            model.edited_overrides(&self.pending_config.property_overrides, edits);
        edited
    }

    pub fn restore_property_default(&mut self, id: &str) {
        self.pending_config.property_overrides.remove(id);
    }

    /// Stages the authored default for every property except those in `keep`,
    /// hidden and stale overrides included. Nothing else in the draft moves,
    /// and the committed config is untouched, so cancelling brings every value
    /// back.
    ///
    /// `keep` holds the file and directory properties: a chosen path is written
    /// to the committed config the moment it is picked, beside the copy the app
    /// keeps of it, so dropping it from a draft alone would leave the two out of
    /// step. Clearing one stays its own action.
    pub fn restore_all_property_defaults(&mut self, keep: &BTreeSet<String>) {
        self.pending_config
            .property_overrides
            .retain(|id, _| keep.contains(id));
    }

    pub fn cancel(&mut self) {
        self.pending_config.clone_from(&self.saved_config);
        self.pending_assignment.clone_from(&self.saved_assignment);
    }

    #[must_use]
    pub fn apply(&mut self) -> WallpaperConfig {
        self.saved_config.clone_from(&self.pending_config);
        self.saved_assignment.clone_from(&self.pending_assignment);
        self.saved_config.clone()
    }

    /// Stages one of Wallpaper Engine's per-wallpaper options, like a property
    /// edit: Apply keeps it and Revert undoes it.
    pub fn edit_engine_option(&mut self, option: EngineOptionId, value: &PropertyValue) {
        self.pending_config.engine_options.set(option, value);
    }

    pub fn restore_engine_option_default(&mut self, option: EngineOptionId) {
        self.pending_config.engine_options.restore(option);
    }

    /// Stages the default of every per-wallpaper option. The authored
    /// properties, display settings and audio are left alone.
    pub fn restore_all_engine_option_defaults(&mut self) {
        self.pending_config.engine_options = EngineOptionsCfg::default();
    }

    /// This draft with `edits` made to its per-wallpaper options one after
    /// another, and this draft left as it is: a slider still being dragged
    /// reaches a preview this way without becoming an edit.
    #[must_use]
    pub fn with_engine_edits(&self, edits: &[(EngineOptionId, PropertyValue)]) -> Self {
        let mut edited = self.clone();
        for (option, value) in edits {
            edited.pending_config.engine_options.set(*option, value);
        }
        edited
    }

    fn check_volume(volume: f32) -> Result<(), BridgeError> {
        if !(0.0..=1.0).contains(&volume) {
            return Err(BridgeError::invalid_input("Volume must be between 0 and 1 inclusive"));
        }
        Ok(())
    }

    fn assignment_intent_changed(&self) -> bool {
        self.pending_assignment.len() != self.saved_assignment.len()
            || self.pending_assignment.iter().any(|selector| !self.saved_assignment.contains(selector))
    }

    fn assignment_discrepancy(&self, active: &[SerializedSelector]) -> bool {
        self.assignment_intent_changed()
            && (self.pending_assignment.iter().any(|selector| !active.contains(selector))
                || active.iter().any(|selector| !self.pending_assignment.contains(selector)))
    }

    fn monitor_for_edit<'a>(
        config: &'a mut WallpaperConfig,
        selector: Cow<'_, SerializedSelector>,
    ) -> &'a mut MonitorRender {
        let index = match config.monitors.iter().position(|row| row.selector == *selector) {
            Some(index) => index,
            None => {
                let index = config.monitors.len();
                config.monitors.push(MonitorRender {
                    selector: selector.into_owned(),
                    ..MonitorRender::default()
                });
                index
            }
        };
        &mut config.monitors[index]
    }

    fn store_scaling_mode(row: &mut MonitorRender, mode: ScalingMode) {
        row.scaling_mode.clear();
        write!(&mut row.scaling_mode, "{mode}").expect("writing a scaling mode to a String cannot fail");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A display override that exists only in the draft and holds nothing but
    /// defaults is not a change; one that holds a position is.
    #[test]
    fn a_position_only_the_draft_holds_still_needs_a_reconcile() {
        let mut draft =
            WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("100", "scene"));
        draft.set_display_render_enabled(SerializedSelector::Primary, true);
        assert!(!draft.requires_reconcile(&[]));

        draft.pending_config.monitors[0].framing = FramingCfg {
            pan_x: 0.2,
            pan_y: 0.8,
        };

        assert!(draft.requires_reconcile(&[]));
    }

    /// The saved configuration is what a cancelled edit falls back to, so it
    /// must not move with the edits and must move on Apply.
    #[test]
    fn the_committed_config_ignores_pending_edits_until_they_are_applied() {
        let model = ProjectModel::parse(
            "100",
            r#"{"type":"scene","title":"T","general":{"properties":{
                "alpha":{"type":"slider","text":"Alpha","value":1,"min":0,"max":1}
            }}}"#,
        )
        .unwrap();
        let mut draft =
            WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("100", "scene"));

        draft.edit_property(&model, "alpha", PropertyValue::Number(0.5));

        assert!(draft.committed().property_overrides.is_empty());
        assert_eq!(draft.current().property_overrides.len(), 1);

        let applied = draft.apply();

        assert_eq!(draft.committed(), &applied);
        assert_eq!(draft.committed().property_overrides.len(), 1);
    }

    const DOCUMENT_PROJECT: &str = r#"{"type":"scene","title":"T","general":{"properties":{
        "alpha":{"type":"slider","text":"Alpha","value":1,"min":0,"max":1},
        "picture":{"type":"scenetexture","text":"Picture","value":""}
    }}}"#;

    /// The two documents are equal exactly when showing the pending edits
    /// would change nothing, which is what lets the bridge send nothing.
    #[test]
    fn the_shown_document_differs_from_the_saved_one_only_by_what_a_scene_can_take() {
        let model = ProjectModel::parse("100", DOCUMENT_PROJECT).unwrap();
        let mut draft =
            WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("100", "scene"));

        let untouched = draft.property_documents(&model);
        assert_eq!(untouched.shown, "{}");
        assert_eq!(untouched.shown, untouched.saved);

        draft.edit_property(&model, "picture", PropertyValue::String("pending.png".into()));
        assert_eq!(
            draft.property_documents(&model),
            untouched,
            "a texture waits for Apply"
        );

        draft.edit_property(&model, "alpha", PropertyValue::Number(0.5));
        let edited = draft.property_documents(&model);
        assert_eq!(edited.shown, r#"{"alpha":0.5}"#);
        assert_eq!(edited.saved, "{}", "the saved document does not follow the edit");

        let applied = draft.apply();
        let mut applied = WallpaperOptionsDraft::from_committed(applied);
        applied.edit_property(&model, "alpha", PropertyValue::Number(1.0));
        let back = applied.property_documents(&model);
        assert_eq!(
            back.shown, r#"{"picture":"pending.png"}"#,
            "an edit back to the authored value leaves it out, and the texture \
             Apply saved is part of every document from then on"
        );
        assert_eq!(back.saved, r#"{"alpha":0.5,"picture":"pending.png"}"#);
    }

    /// A value that is only being shown goes on top of the draft in the order
    /// it is given, the way edits would, and the draft never learns of it.
    #[test]
    fn edits_made_for_showing_leave_the_draft_alone_and_land_in_order() {
        let model = ProjectModel::parse("100", DOCUMENT_PROJECT).unwrap();
        let mut draft =
            WallpaperOptionsDraft::from_committed(WallpaperConfig::new_for("100", "scene"));
        draft.edit_property(&model, "alpha", PropertyValue::Number(0.5));
        let before = draft.current().clone();

        let shown = draft.with_edits(
            &model,
            &[
                ("alpha".to_string(), PropertyValue::Number(0.25)),
                ("alpha".to_string(), PropertyValue::Number(0.75)),
            ],
        );

        assert_eq!(draft.current(), &before, "the draft is as it was");
        assert!(draft.is_dirty(&[]), "and just as dirty");
        assert_eq!(shown.property_documents(&model).shown, r#"{"alpha":0.75}"#);
        let defaulted = draft.with_edits(
            &model,
            &[("alpha".to_string(), PropertyValue::Number(1.0))],
        );
        assert_eq!(
            defaulted.property_documents(&model).shown,
            "{}",
            "a value shown at the authored default leaves the property out, as an edit does"
        );
        assert_eq!(
            draft.with_edits(&model, &[]).current(),
            draft.current(),
            "nothing pending shows the draft"
        );
    }
}

#[cfg(test)]
mod contract_tests;
