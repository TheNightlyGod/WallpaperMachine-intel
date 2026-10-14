use std::collections::{BTreeMap, BTreeSet};

use wallpaper_core::project::ScalingMode;

use crate::{
    api::BridgeError,
    config::{FramingCfg, MonitorRender, SerializedSelector, WallpaperConfig},
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
    committed: WallpaperConfig,
    current: WallpaperConfig,
    committed_enabled_displays: Vec<SerializedSelector>,
    current_enabled_displays: Vec<SerializedSelector>,
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
            current: committed.clone(),
            committed,
            committed_enabled_displays: enabled_displays.clone(),
            current_enabled_displays: enabled_displays,
        }
    }

    #[must_use]
    pub fn current(&self) -> &WallpaperConfig {
        &self.current
    }

    /// What is saved, as opposed to the pending edits in [`Self::current`].
    #[must_use]
    pub fn committed(&self) -> &WallpaperConfig {
        &self.committed
    }

    /// The documents of this draft, for showing its property edits on a
    /// running scene.
    #[must_use]
    pub fn property_documents(&self, model: &ProjectModel) -> PropertyDocuments {
        property_documents(model, &self.committed, &self.current)
    }

    #[must_use]
    pub fn is_dirty(&self, active_enabled_displays: &[SerializedSelector]) -> bool {
        self.current != self.committed || self.enabled_dirty(active_enabled_displays)
    }

    #[must_use]
    pub fn requires_reconcile(&self, active_enabled_displays: &[SerializedSelector]) -> bool {
        self.enabled_dirty(active_enabled_displays) || {
            let mut current = self.current.clone();
            let mut committed = self.committed.clone();
            current.audio = committed.audio.clone();
            for current_render in &mut current.monitors {
                if let Some(committed_render) = committed
                    .monitors
                    .iter_mut()
                    .find(|render| render.selector == current_render.selector)
                {
                    current_render.scaling_factor = committed_render.scaling_factor;
                } else if current_render.scaling_mode == MonitorRender::default().scaling_mode
                    && current_render.frame_rate == MonitorRender::default().frame_rate
                    && current_render.framing == MonitorRender::default().framing
                {
                    current_render.scaling_factor = MonitorRender::default().scaling_factor;
                    committed.monitors.push(current_render.clone());
                }
            }
            current != committed
        }
    }

    /// # Errors
    ///
    /// Returns an error when `volume` is outside the inclusive `0.0..=1.0`
    /// range.
    pub fn set_volume(&mut self, volume: f32) -> Result<(), BridgeError> {
        if !(0.0..=1.0).contains(&volume) {
            return Err(BridgeError::invalid_input(
                "wallpaper volume must be between 0 and 1",
            ));
        }

        self.current.audio.volume = volume;
        Ok(())
    }

    /// # Errors
    ///
    /// Returns an error when `volume` is outside the inclusive `0.0..=1.0`
    /// range.
    pub fn set_volume_immediate(&mut self, volume: f32) -> Result<WallpaperConfig, BridgeError> {
        self.set_volume(volume)?;
        self.committed.audio.volume = volume;
        Ok(self.committed.clone())
    }

    pub fn set_muted(&mut self, muted: bool) {
        self.current.audio.muted = muted;
    }

    #[must_use]
    pub fn set_muted_immediate(&mut self, muted: bool) -> WallpaperConfig {
        self.set_muted(muted);
        self.committed.audio.muted = muted;
        self.committed.clone()
    }

    pub fn set_audio_response_enabled(&mut self, enabled: bool) {
        self.current.audio.response_enabled = enabled;
    }

    #[must_use]
    pub fn set_audio_response_enabled_immediate(&mut self, enabled: bool) -> WallpaperConfig {
        self.set_audio_response_enabled(enabled);
        self.committed.audio.response_enabled = enabled;
        self.committed.clone()
    }

    /// Media integration is applied immediately, like audio response: it is a
    /// switch the user flips, not an option staged behind Apply.
    #[must_use]
    pub fn set_media_integration_enabled_immediate(&mut self, enabled: bool) -> WallpaperConfig {
        self.current.media_integration_enabled = enabled;
        self.committed.media_integration_enabled = enabled;
        self.committed.clone()
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
        model.edit_overrides(&mut self.current.property_overrides, id, value.clone());
        model.edit_overrides(&mut self.committed.property_overrides, id, value);
        self.committed.clone()
    }

    pub fn set_display_enabled(
        &mut self,
        selector: SerializedSelector,
        enabled: bool,
        active_enabled_displays: &[SerializedSelector],
    ) {
        self.set_display_aliases_enabled(&[selector], enabled, active_enabled_displays);
    }

    pub fn set_display_aliases_enabled(
        &mut self,
        selectors: &[SerializedSelector],
        enabled: bool,
        active_enabled_displays: &[SerializedSelector],
    ) {
        if !self.enabled_displays_dirty() {
            self.current_enabled_displays = active_enabled_displays.to_vec();
            self.committed_enabled_displays = active_enabled_displays.to_vec();
        }

        if enabled {
            for selector in selectors {
                if !self.current_enabled_displays.contains(selector) {
                    self.current_enabled_displays.push(selector.clone());
                }
            }
        } else {
            self.current_enabled_displays
                .retain(|candidate| !selectors.contains(candidate));
        }
    }

    #[must_use]
    pub fn display_enabled(&self, selector: &SerializedSelector) -> bool {
        self.current_enabled_displays.contains(selector)
    }

    #[must_use]
    pub fn display_dirty(
        &self,
        selector: &SerializedSelector,
        active_enabled_displays: &[SerializedSelector],
    ) -> bool {
        self.enabled_displays_dirty()
            && self.current_enabled_displays.contains(selector)
                != active_enabled_displays.contains(selector)
    }

    #[must_use]
    pub fn enabled_displays(&self) -> &[SerializedSelector] {
        &self.current_enabled_displays
    }

    pub fn rebase_enabled_displays(&mut self, enabled_displays: Vec<SerializedSelector>) {
        self.committed_enabled_displays
            .clone_from(&enabled_displays);
        self.current_enabled_displays = enabled_displays;
    }

    #[must_use]
    pub fn effective_display_enabled(
        &self,
        selector: &SerializedSelector,
        active_enabled_displays: &[SerializedSelector],
    ) -> bool {
        if self.display_dirty(selector, active_enabled_displays) {
            return self.display_enabled(selector);
        }
        active_enabled_displays.contains(selector)
    }

    #[must_use]
    pub fn effective_enabled_displays(
        &self,
        active_enabled_displays: &[SerializedSelector],
    ) -> Vec<SerializedSelector> {
        let mut selectors = self.current_enabled_displays.clone();
        for selector in &self.committed_enabled_displays {
            if !selectors.contains(selector) {
                selectors.push(selector.clone());
            }
        }
        for selector in active_enabled_displays {
            if !selectors.contains(selector) {
                selectors.push(selector.clone());
            }
        }

        selectors
            .into_iter()
            .filter(|selector| self.effective_display_enabled(selector, active_enabled_displays))
            .collect()
    }

    pub fn set_display_render_enabled(&mut self, selector: SerializedSelector, enabled: bool) {
        if enabled {
            let _ = self.ensure_monitor_render(selector);
        } else {
            self.current
                .monitors
                .retain(|render| render.selector != selector);
        }
    }

    pub fn set_scaling_mode(&mut self, selector: SerializedSelector, mode: ScalingMode) {
        self.ensure_monitor_render(selector).scaling_mode = mode.to_string();
    }

    #[must_use]
    pub fn set_scaling_mode_immediate(
        &mut self,
        selector: SerializedSelector,
        mode: ScalingMode,
    ) -> WallpaperConfig {
        self.set_scaling_mode(selector.clone(), mode);
        self.committed
            .monitors
            .iter_mut()
            .find(|render| render.selector == selector)
            .map(|render| render.scaling_mode = mode.to_string())
            .unwrap_or_else(|| {
                self.committed.monitors.push(MonitorRender {
                    selector,
                    scaling_mode: mode.to_string(),
                    ..MonitorRender::default()
                });
            });
        self.committed.clone()
    }

    /// # Errors
    ///
    /// Returns an error when `factor` is not finite and greater than 0.
    pub fn set_scaling_factor(
        &mut self,
        selector: SerializedSelector,
        factor: f64,
    ) -> Result<(), BridgeError> {
        if !factor.is_finite() || factor <= 0.0 {
            return Err(BridgeError::invalid_input(
                "scaling factor must be finite and greater than 0",
            ));
        }

        self.ensure_monitor_render(selector).scaling_factor = factor;
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
        let saved = saved_framing(&self.committed, &selector);
        let framing = moved_framing(saved, pan_x, pan_y)?;
        if framing == saved {
            return Ok(PositionUpdate {
                config: self.committed.clone(),
                framing,
                previous: saved,
                changed: false,
            });
        }

        self.ensure_monitor_render(selector.clone()).framing = framing;
        match self
            .committed
            .monitors
            .iter_mut()
            .find(|render| render.selector == selector)
        {
            Some(render) => render.framing = framing,
            None => self.committed.monitors.push(MonitorRender {
                selector,
                framing,
                ..MonitorRender::default()
            }),
        }
        Ok(PositionUpdate {
            config: self.committed.clone(),
            framing,
            previous: saved,
            changed: true,
        })
    }

    pub fn set_target_fps(&mut self, selector: SerializedSelector, fps: u32, max_fps: u32) {
        self.ensure_monitor_render(selector).frame_rate =
            crate::config::stored_frame_rate(fps, max_fps);
    }

    #[must_use]
    pub fn set_target_fps_immediate(
        &mut self,
        selector: SerializedSelector,
        fps: u32,
        max_fps: u32,
    ) -> WallpaperConfig {
        self.set_target_fps(selector.clone(), fps, max_fps);
        let frame_rate = self
            .current
            .monitors
            .iter()
            .find(|render| render.selector == selector)
            .and_then(|render| render.frame_rate);
        self.committed
            .monitors
            .iter_mut()
            .find(|render| render.selector == selector)
            .map(|render| render.frame_rate = frame_rate)
            .unwrap_or_else(|| {
                self.committed.monitors.push(MonitorRender {
                    selector,
                    frame_rate,
                    ..MonitorRender::default()
                });
            });
        self.committed.clone()
    }

    pub fn edit_property(&mut self, model: &ProjectModel, id: &str, value: PropertyValue) {
        model.edit_overrides(&mut self.current.property_overrides, id, value);
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
        edited.current.property_overrides =
            model.edited_overrides(&self.current.property_overrides, edits);
        edited
    }

    pub fn restore_property_default(&mut self, id: &str) {
        self.current.property_overrides.remove(id);
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
        self.current
            .property_overrides
            .retain(|id, _| keep.contains(id));
    }

    pub fn cancel(&mut self) {
        self.current = self.committed.clone();
        self.current_enabled_displays = self.committed_enabled_displays.clone();
    }

    #[must_use]
    pub fn apply(&mut self) -> WallpaperConfig {
        self.committed = self.current.clone();
        self.committed_enabled_displays = self.current_enabled_displays.clone();
        self.committed.clone()
    }

    fn ensure_monitor_render(&mut self, selector: SerializedSelector) -> &mut MonitorRender {
        if let Some(index) = self
            .current
            .monitors
            .iter()
            .position(|render| render.selector == selector)
        {
            return &mut self.current.monitors[index];
        }

        self.current.monitors.push(MonitorRender {
            selector,
            ..MonitorRender::default()
        });
        self.current
            .monitors
            .last_mut()
            .expect("monitor render was just inserted")
    }

    fn enabled_displays_dirty(&self) -> bool {
        self.current_enabled_displays.len() != self.committed_enabled_displays.len()
            || !self
                .current_enabled_displays
                .iter()
                .all(|selector| self.committed_enabled_displays.contains(selector))
    }

    fn enabled_dirty(&self, active_enabled_displays: &[SerializedSelector]) -> bool {
        let mut selectors = self.current_enabled_displays.clone();
        for selector in &self.committed_enabled_displays {
            if !selectors.contains(selector) {
                selectors.push(selector.clone());
            }
        }
        for selector in active_enabled_displays {
            if !selectors.contains(selector) {
                selectors.push(selector.clone());
            }
        }

        selectors
            .iter()
            .any(|selector| self.display_dirty(selector, active_enabled_displays))
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

        draft.current.monitors[0].framing = FramingCfg {
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
