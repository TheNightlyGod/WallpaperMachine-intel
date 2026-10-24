// Clean-room implementation from the WallpaperMachine spec r1b-core-display.md; written without access to the original source.
use std::collections::HashSet;

#[cfg(test)]
use crate::{DisplayConfig, project::SceneTemplate};
use crate::{
    DisplayDesc, DisplayIdentity, DisplaySelector, EngineError, WallpaperAssignment,
    WallpaperEngineConfig,
    project::{SceneDesc, SceneTemplate as Template},
};

/// The name of a display slot in the model.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum DisplayKey {
    Primary,
    Identity(DisplayIdentity),
    LiveDisplayId(u32),
}

/// What the engine must do with the scene of one slot after a model change.
#[derive(Clone, Debug, PartialEq)]
pub enum DisplayAction {
    Open(DisplayKey),
    Close(DisplayKey),
    Rebuild(DisplayKey),
}

/// One display slot: its key, live display, assignment and flags.
#[derive(Clone, Debug, PartialEq)]
pub struct DisplayRecord {
    pub key: DisplayKey,
    pub live_display: Option<DisplayDesc>,
    pub assignment: Option<WallpaperAssignment>,
    pub window_active: bool,
    pub runtime_open: bool,
    pub primary_inheritance_consumed: bool,
    /// Whether the assignment is the one a reconcile asked for this slot's
    /// concrete display. A bound assignment stays with its physical display
    /// when another display becomes the main one; an unbound one (configured,
    /// set directly or inherited) stays with its key, so on the primary slot
    /// it follows the main display.
    pub bound_to_display: bool,
}

impl DisplayRecord {
    /// Whether a scene should exist for this slot: its window is active or
    /// a scene is already open, a display is connected and something is
    /// assigned (a mirror counts; the engine resolves mirrors first).
    pub fn should_have_runtime(&self) -> bool {
        (self.window_active || self.runtime_open)
            && self.live_display.is_some()
            && self.assignment.is_some()
    }

    pub fn scene_desc(&self) -> Result<Option<SceneDesc>, EngineError> {
        let Some(display) = &self.live_display else {
            return Ok(None);
        };
        match &self.assignment {
            None => Ok(None),
            Some(WallpaperAssignment::Direct(template)) => {
                template.validate()?;
                Ok(Some(template.for_display(display.clone())))
            }
            Some(WallpaperAssignment::Mirror(_)) => Err(EngineError::Platform(
                "mirror assignments must be resolved before runtime creation".to_string(),
            )),
        }
    }

    /// A slot that came into being without any configuration: inactive,
    /// disconnected and blank.
    fn blank(key: DisplayKey) -> Self {
        Self {
            key,
            live_display: None,
            assignment: None,
            window_active: false,
            runtime_open: false,
            primary_inheritance_consumed: false,
            bound_to_display: false,
        }
    }

    /// Whether the slot's wallpaper claims its display for a scene to run
    /// on it right now (before mirrors are resolved).
    fn is_claimed(&self) -> bool {
        self.window_active || self.runtime_open
    }
}

/// A display transition worth a debug line.
#[derive(Clone, Debug, PartialEq)]
pub enum DisplayDebugEvent {
    Connected {
        key: DisplayKey,
        display: DisplayDesc,
    },
    Disconnected {
        key: DisplayKey,
        display: DisplayDesc,
    },
    Changed {
        key: DisplayKey,
        before: DisplayDesc,
        after: DisplayDesc,
    },
}

/// All display slots, primary first, then in order of creation.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct DisplayStateModel {
    pub records: Vec<DisplayRecord>,
}

impl DisplayKey {
    pub fn key_label(&self) -> String {
        match self {
            Self::Primary => "the primary slot".to_owned(),
            Self::Identity(identity) => format!("slot for {}", identity.identity_label()),
            Self::LiveDisplayId(id) => format!("slot for live display #{id}"),
        }
    }

    pub fn from_selector(selector: &DisplaySelector) -> Result<Self, EngineError> {
        match selector {
            DisplaySelector::Primary => Ok(Self::Primary),
            DisplaySelector::Identity(identity) if identity.is_empty() => {
                Err(EngineError::InvalidInput(
                    "display identity selector must not be empty".to_string(),
                ))
            }
            DisplaySelector::Identity(identity) => Ok(Self::Identity(identity.clone())),
            DisplaySelector::LiveDisplayId(0) => Err(EngineError::InvalidInput(
                "display_id must be non-zero".to_string(),
            )),
            DisplaySelector::LiveDisplayId(id) => Ok(Self::LiveDisplayId(*id)),
        }
    }
}

fn mirror_cycle_error() -> EngineError {
    EngineError::InvalidInput("wallpaper mirror cycle detected".to_string())
}

impl DisplayStateModel {
    pub fn from_config(config: WallpaperEngineConfig) -> Result<Self, EngineError> {
        // Read every entry first, so a mirror loop spanning two entries is
        // judged on the complete configuration.
        let entries = config
            .displays
            .into_iter()
            .map(|entry| {
                if let Some(WallpaperAssignment::Direct(template)) = &entry.wallpaper {
                    template.validate()?;
                }
                let key = DisplayKey::from_selector(&entry.selector)?;
                Ok((key, entry.window_active, entry.wallpaper))
            })
            .collect::<Result<Vec<_>, EngineError>>()?;

        let mut model = Self {
            records: vec![DisplayRecord {
                window_active: true,
                ..DisplayRecord::blank(DisplayKey::Primary)
            }],
        };
        for (key, window_active, assignment) in entries {
            let slot = model.slot_or_insert(key);
            slot.window_active = window_active;
            slot.assignment = assignment;
        }
        model.check_mirror_cycles()?;
        Ok(model)
    }

    pub fn set_assignment(
        &mut self,
        selector: &DisplaySelector,
        assignment: WallpaperAssignment,
    ) -> Result<(), EngineError> {
        if let WallpaperAssignment::Direct(template) = &assignment {
            template.validate()?;
        }
        let key = DisplayKey::from_selector(selector)?;
        let slots_before = self.records.len();
        let index = self.index_or_insert(key);
        let replaced = self.records[index].assignment.replace(assignment);
        // Set another way than by a reconcile: the slot's key decides.
        let was_bound = std::mem::take(&mut self.records[index].bound_to_display);
        if let Err(error) = self.check_mirror_cycles() {
            // Undo: a slot made for this call is the last one.
            self.records[index].assignment = replaced;
            self.records[index].bound_to_display = was_bound;
            self.records.truncate(slots_before);
            return Err(error);
        }
        Ok(())
    }

    pub fn refresh_connected(
        &mut self,
        primary: DisplayDesc,
        displays: Vec<DisplayDesc>,
    ) -> Result<Vec<DisplayAction>, EngineError> {
        self.refresh_connected_keeping(primary, displays, &[])
    }

    /// Like [`Self::refresh_connected`], for a report in which some displays
    /// have no pixel size yet (`transitional`, absent from `displays`).
    ///
    /// A transitional display that already has a descriptor keeps it, so its
    /// runtime is neither closed nor rebuilt while the display settles. One
    /// that has none gets no live descriptor, so nothing opens on it.
    pub fn refresh_connected_keeping(
        &mut self,
        primary: DisplayDesc,
        displays: Vec<DisplayDesc>,
        transitional: &[DisplayDesc],
    ) -> Result<Vec<DisplayAction>, EngineError> {
        let target = self.model_after_report(&primary, displays, transitional)?;
        let plan = target.scene_plan()?;
        target.log_debug_transition(self);
        *self = target;
        Ok(plan)
    }

    pub fn set_window_active(
        &mut self,
        selector: &DisplaySelector,
        active: bool,
    ) -> Result<Vec<DisplayAction>, EngineError> {
        let key = DisplayKey::from_selector(selector)?;
        let mut next = self.clone();
        next.slot_or_insert(key).window_active = active;
        let actions = next.scene_plan()?;
        *self = next;
        Ok(actions)
    }

    pub fn destroy_window(
        &mut self,
        selector: &DisplaySelector,
    ) -> Result<Vec<DisplayAction>, EngineError> {
        let key = DisplayKey::from_selector(selector)?;
        let slot = self.slot_or_insert(key.clone());
        slot.window_active = false;
        let had_scene = std::mem::take(&mut slot.runtime_open);
        Ok(had_scene
            .then_some(DisplayAction::Close(key))
            .into_iter()
            .collect())
    }

    pub fn resolved_assignment(
        &self,
        key: &DisplayKey,
    ) -> Result<Option<WallpaperAssignment>, EngineError> {
        let Some(mut record) = self.slot(key) else {
            return Ok(None);
        };
        let mut visited = vec![&record.key];
        loop {
            match &record.assignment {
                None => return Ok(None),
                Some(direct @ WallpaperAssignment::Direct(_)) => return Ok(Some(direct.clone())),
                Some(WallpaperAssignment::Mirror(source)) => {
                    let source_key = DisplayKey::from_selector(source)?;
                    let Some(source_record) = self.slot(&source_key) else {
                        return Ok(None);
                    };
                    if visited.contains(&&source_record.key) {
                        return Err(mirror_cycle_error());
                    }
                    visited.push(&source_record.key);
                    record = source_record;
                }
            }
        }
    }

    pub fn apply_reconcile(&mut self, scenes: &[SceneDesc]) -> Result<(), EngineError> {
        // Every placement is decided against the model as it is now.
        let keys = scenes
            .iter()
            .map(|scene| self.reconcile_key(scene))
            .collect::<Result<Vec<_>, _>>()?;
        let mut next = self.clone();
        for record in &mut next.records {
            if record.live_display.is_some() && !keys.contains(&record.key) {
                record.window_active = false;
                record.runtime_open = false;
                record.bound_to_display = false;
            }
        }
        for (scene, key) in scenes.iter().zip(keys) {
            let record = next.slot_or_insert(key);
            record.live_display = Some(scene.display.clone());
            record.window_active = true;
            record.assignment = Some(WallpaperAssignment::Direct(Template::from_scene_desc(
                scene,
            )));
            // Asked for this concrete display: it stays with the display.
            record.bound_to_display = true;
        }
        *self = next;
        Ok(())
    }

    pub fn reconcile_key(&self, scene: &SceneDesc) -> Result<DisplayKey, EngineError> {
        let display = &scene.display;
        let shows_display = |record: &&DisplayRecord| {
            record
                .live_display
                .as_ref()
                .is_some_and(|live| live.display_id == display.display_id)
        };
        let primary_shows = self
            .slot(&DisplayKey::Primary)
            .iter()
            .any(|record| shows_display(record));
        if primary_shows {
            return Ok(DisplayKey::Primary);
        }
        if let Some(record) = self.records.iter().find(shows_display) {
            return Ok(record.key.clone());
        }
        if !display.identity.is_empty()
            && let Some(key) = self.best_identity_slot(&display.identity, display.display_id)?
        {
            return Ok(key);
        }
        Ok(DisplayKey::LiveDisplayId(display.display_id))
    }

    pub fn has_live_id(&self, display_id: u32) -> bool {
        self.records.iter().any(|record| {
            record
                .live_display
                .as_ref()
                .is_some_and(|live| live.display_id == display_id)
        })
    }

    pub fn debug_events_since(&self, before: &DisplayStateModel) -> Vec<DisplayDebugEvent> {
        let mut events = Vec::new();
        for record in &self.records {
            if let Some(display) = &record.live_display
                && !before.has_live_id(display.display_id)
            {
                events.push(DisplayDebugEvent::Connected {
                    key: record.key.clone(),
                    display: display.clone(),
                });
            }
        }
        for record in &before.records {
            if let Some(display) = &record.live_display
                && !self.has_live_id(display.display_id)
            {
                events.push(DisplayDebugEvent::Disconnected {
                    key: record.key.clone(),
                    display: display.clone(),
                });
            }
        }
        for record in &self.records {
            let (Some(after), Some(old)) = (
                &record.live_display,
                before
                    .slot(&record.key)
                    .and_then(|old| old.live_display.as_ref()),
            ) else {
                continue;
            };
            if !old.has_same_geometry(after) {
                events.push(DisplayDebugEvent::Changed {
                    key: record.key.clone(),
                    before: old.clone(),
                    after: after.clone(),
                });
            }
        }
        events
    }

    pub fn log_debug_transition(&self, before: &DisplayStateModel) {
        for event in self.debug_events_since(before) {
            match event {
                DisplayDebugEvent::Connected { key, display } => log::debug!(
                    "[wallpaper-core display] connected {} on {}",
                    display.desc_label(),
                    key.key_label()
                ),
                DisplayDebugEvent::Disconnected { key, display } => log::debug!(
                    "[wallpaper-core display] disconnected {} from {}",
                    display.desc_label(),
                    key.key_label()
                ),
                DisplayDebugEvent::Changed { key, before, after } => log::debug!(
                    "[wallpaper-core display] changed {}: {} -> {}",
                    key.key_label(),
                    before.desc_label(),
                    after.desc_label()
                ),
            }
        }
    }

    // ---- private helpers -------------------------------------------------

    fn slot(&self, key: &DisplayKey) -> Option<&DisplayRecord> {
        self.records.iter().find(|record| &record.key == key)
    }

    /// Position of the slot named `key`; a blank inactive slot is appended
    /// first when there is none.
    fn index_or_insert(&mut self, key: DisplayKey) -> usize {
        self.records
            .iter()
            .position(|record| record.key == key)
            .unwrap_or_else(|| {
                self.records.push(DisplayRecord::blank(key));
                self.records.len() - 1
            })
    }

    fn slot_or_insert(&mut self, key: DisplayKey) -> &mut DisplayRecord {
        let index = self.index_or_insert(key);
        &mut self.records[index]
    }

    /// The model a display report leads to, computed without touching
    /// `self`: every key decision reads the slots as they stand now.
    fn model_after_report(
        &self,
        primary: &DisplayDesc,
        displays: Vec<DisplayDesc>,
        transitional: &[DisplayDesc],
    ) -> Result<Self, EngineError> {
        let landings = self.landings(primary, displays)?;
        let primary_assignment = self
            .slot(&DisplayKey::Primary)
            .and_then(|record| record.assignment.clone());

        // Existing slots keep their place; slots born in this report follow
        // in the order their displays were listed.
        let mut keys: Vec<&DisplayKey> = self.records.iter().map(|record| &record.key).collect();
        keys.extend(
            landings
                .iter()
                .map(|(key, _)| key)
                .filter(|key| self.slot(key).is_none()),
        );

        let records = keys
            .into_iter()
            .map(|key| {
                let before = self.slot(key);
                let landed = landings
                    .iter()
                    .find(|(landing_key, _)| landing_key == key)
                    .map(|(_, display)| display);
                let mut record = before
                    .cloned()
                    .unwrap_or_else(|| DisplayRecord::blank(key.clone()));
                // A display that still reports no pixels keeps the slot it
                // ran on.
                record.live_display = landed.cloned().or_else(|| {
                    before
                        .and_then(|old| old.live_display.as_ref())
                        .filter(|previous| {
                            transitional
                                .iter()
                                .any(|display| previous.is_same_physical_display_as(display))
                        })
                        .cloned()
                });
                if let Some(display) = landed {
                    let eligible = !record.primary_inheritance_consumed
                        && record.assignment.is_none()
                        && display.display_id != primary.display_id;
                    if eligible {
                        record.assignment.clone_from(&primary_assignment);
                        record.primary_inheritance_consumed = true;
                        record.bound_to_display = false;
                    }
                }
                record
            })
            .collect();

        let mut candidate = Self { records };
        candidate.hand_over_bound_assignments(self, transitional);
        candidate.check_mirror_cycles()?;
        candidate.carry_scene_marks_from(self)?;
        Ok(candidate)
    }

    /// Moves each assignment bound to its display to the slot that holds that
    /// display after a report (`self`, built from `earlier`), so a change of
    /// main display does not swap wallpapers between displays.
    ///
    /// The old main display's wallpaper leaves the primary slot for that
    /// display's own slot, also when the display is gone: the slot keeps it
    /// until the display returns. A bound wallpaper whose display became the
    /// main one moves into the primary slot, unless the primary slot holds a
    /// configured (unbound) wallpaper, which keeps following the main display.
    /// A display still connecting keeps the descriptor it ran with, as it does
    /// on its own slot. A gone display whose own slot cannot be told (two slots
    /// name it equally well) leaves its wallpaper where it is.
    fn hand_over_bound_assignments(&mut self, earlier: &Self, transitional: &[DisplayDesc]) {
        let mut moves: Vec<(&DisplayRecord, DisplayKey)> = Vec::new();
        for old in &earlier.records {
            let (true, Some(WallpaperAssignment::Direct(_)), Some(display)) =
                (old.bound_to_display, &old.assignment, &old.live_display)
            else {
                continue;
            };
            let holder = self.records.iter().find(|record| {
                record
                    .live_display
                    .as_ref()
                    .is_some_and(|live| live.is_same_physical_display_as(display))
            });
            let destination = match holder {
                Some(record) => record.key.clone(),
                None => match self.slot_for_display(display) {
                    Ok(key) => key,
                    Err(_) => continue,
                },
            };
            if destination != old.key {
                moves.push((old, destination));
            }
        }
        let leaving = |key: &DisplayKey| moves.iter().any(|(old, _)| &old.key == key);
        let mut accepted: Vec<(&DisplayRecord, DisplayKey)> = Vec::new();
        for (old, destination) in &moves {
            // A slot keeps a bound wallpaper that stays, and the primary slot
            // keeps a configured one; anything else gives way.
            let keeps_own = earlier.slot(destination).is_some_and(|current| {
                current.assignment.is_some()
                    && if current.bound_to_display {
                        !leaving(&current.key)
                    } else {
                        current.key == DisplayKey::Primary
                    }
            });
            let taken = accepted.iter().any(|(_, to)| to == destination);
            if !keeps_own && !taken {
                accepted.push((old, destination.clone()));
            }
        }
        for (old, _) in &accepted {
            if let Some(source) = self.records.iter_mut().find(|record| record.key == old.key) {
                source.assignment = None;
                source.bound_to_display = false;
            }
        }
        for (old, destination) in accepted {
            let record = self.slot_or_insert(destination);
            record.assignment.clone_from(&old.assignment);
            record.bound_to_display = true;
            record.window_active = old.window_active;
            if record.live_display.is_none() {
                record.live_display = old.live_display.clone().filter(|previous| {
                    transitional
                        .iter()
                        .any(|display| previous.is_same_physical_display_as(display))
                });
            }
        }
    }

    /// The slot every connected display of a report lands on, primary first.
    fn landings(
        &self,
        primary: &DisplayDesc,
        displays: Vec<DisplayDesc>,
    ) -> Result<Vec<(DisplayKey, DisplayDesc)>, EngineError> {
        let mut landings = vec![(self.slot_for_primary(primary), primary.clone())];
        for display in displays {
            // A mirrored or duplicated listing of the primary is not a
            // second display.
            if display.display_id == primary.display_id
                || primary.identity.match_score(&display.identity).is_some()
            {
                continue;
            }
            landings.push((self.slot_for_display(&display)?, display));
        }
        let mut seen = HashSet::new();
        if let Some((key, _)) = landings.iter().find(|(key, _)| !seen.insert(key)) {
            return Err(EngineError::InvalidInput(format!(
                "multiple connected displays matched the display slot {}",
                key.key_label()
            )));
        }
        Ok(landings)
    }

    /// The identity slot whose key names `identity` best (its own identity
    /// is the matcher), `None` without any match; a tie at the top is an
    /// error.
    fn best_identity_slot(
        &self,
        identity: &DisplayIdentity,
        display_id: u32,
    ) -> Result<Option<DisplayKey>, EngineError> {
        let mut best: Option<(u8, &DisplayKey)> = None;
        let mut tied = false;
        for record in &self.records {
            let DisplayKey::Identity(configured) = &record.key else {
                continue;
            };
            let Some(score) = configured.match_score(identity) else {
                continue;
            };
            match best {
                Some((top, _)) if score < top => {}
                Some((top, _)) if score == top => tied = true,
                _ => {
                    best = Some((score, &record.key));
                    tied = false;
                }
            }
        }
        if tied {
            return Err(EngineError::InvalidInput(format!(
                "ambiguous display identity match for display {display_id}"
            )));
        }
        Ok(best.map(|(_, key)| key.clone()))
    }

    /// The slot the primary display lands on.
    fn slot_for_primary(&self, primary: &DisplayDesc) -> DisplayKey {
        if self.slot(&DisplayKey::Primary).is_some_and(DisplayRecord::is_claimed) {
            return DisplayKey::Primary;
        }
        let live_id = DisplayKey::LiveDisplayId(primary.display_id);
        if self.slot(&live_id).is_some_and(DisplayRecord::is_claimed) {
            return live_id;
        }
        DisplayKey::Primary
    }

    /// The slot a non-primary display lands on.
    fn slot_for_display(&self, display: &DisplayDesc) -> Result<DisplayKey, EngineError> {
        let live_id = DisplayKey::LiveDisplayId(display.display_id);
        if self.slot(&live_id).is_some_and(DisplayRecord::is_claimed) {
            return Ok(live_id);
        }
        if !display.identity.is_empty()
            && let Some(key) = self.best_identity_slot(&display.identity, display.display_id)?
        {
            return Ok(key);
        }
        if self
            .slot(&live_id)
            .is_some_and(|record| record.assignment.is_some())
        {
            return Ok(live_id);
        }
        Ok(if display.identity.is_empty() {
            live_id
        } else {
            DisplayKey::Identity(display.identity.clone())
        })
    }

    /// Fails when any chain of mirrors loops back on itself.
    fn check_mirror_cycles(&self) -> Result<(), EngineError> {
        for start in &self.records {
            let mut visited = vec![&start.key];
            let mut current = start;
            while let Some(WallpaperAssignment::Mirror(source)) = &current.assignment {
                // A source nobody can name ends the chain; resolving it
                // reports the problem.
                let Ok(source_key) = DisplayKey::from_selector(source) else {
                    break;
                };
                let Some(next) = self.slot(&source_key) else {
                    break;
                };
                if visited.contains(&&next.key) {
                    return Err(mirror_cycle_error());
                }
                visited.push(&next.key);
                current = next;
            }
        }
        Ok(())
    }

    /// Whether a scene should run on the slot: it is claimed, connected and
    /// its assignment ends in a direct template.
    fn wants_scene(&self, record: &DisplayRecord) -> Result<bool, EngineError> {
        if !record.is_claimed() || record.live_display.is_none() {
            return Ok(false);
        }
        let resolved = self.resolved_assignment(&record.key)?;
        Ok(matches!(resolved, Some(WallpaperAssignment::Direct(_))))
    }

    /// Lets each open scene of `earlier` follow its physical display to the
    /// slot that names it in `self`, the freshly refreshed model. A slot
    /// that does not want a scene ends up with no mark.
    fn carry_scene_marks_from(&mut self, earlier: &Self) -> Result<(), EngineError> {
        let mut used = vec![false; earlier.records.len()];
        let mut marks = Vec::with_capacity(self.records.len());
        for record in &self.records {
            if !self.wants_scene(record)? {
                marks.push(false);
                continue;
            }
            let same_display = |index: usize, old: &DisplayRecord| {
                !used[index]
                    && old.runtime_open
                    && matches!(
                        (&old.live_display, &record.live_display),
                        (Some(before), Some(now)) if before.is_same_physical_display_as(now)
                    )
            };
            let donor = earlier
                .records
                .iter()
                .enumerate()
                .find(|&(index, old)| same_display(index, old))
                .or_else(|| {
                    earlier
                        .records
                        .iter()
                        .enumerate()
                        .find(|&(index, old)| !used[index] && old.key == record.key)
                });
            marks.push(donor.is_some_and(|(index, old)| {
                used[index] = true;
                old.runtime_open
            }));
        }
        for (record, mark) in self.records.iter_mut().zip(marks) {
            record.runtime_open = mark;
        }
        Ok(())
    }

    /// What each slot's scene must do, in slot order.
    fn scene_plan(&self) -> Result<Vec<DisplayAction>, EngineError> {
        let mut plan = Vec::new();
        for record in &self.records {
            let key = record.key.clone();
            plan.extend(match (self.wants_scene(record)?, record.runtime_open) {
                (true, false) => Some(DisplayAction::Open(key)),
                (true, true) => Some(DisplayAction::Rebuild(key)),
                (false, true) => Some(DisplayAction::Close(key)),
                (false, false) => None,
            });
        }
        Ok(plan)
    }
}

#[cfg(test)]
mod model_contract;

#[cfg(test)]
mod main_display_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use super::model_contract::{contract_display, running_layout};

    fn no_pixels(id: u32, identity: DisplayIdentity) -> DisplayDesc {
        DisplayDesc::with_identity(id, identity, 1920, 0, 0, 0, 1.0)
    }

    #[test]
    fn a_running_display_that_reports_no_pixels_keeps_its_descriptor_and_runtime() {
        let layout = running_layout();
        let external = layout.secondary_display.identity.clone();
        let key = DisplayKey::Identity(external.clone());
        let mut model = layout.model;
        let primary = layout.primary_display;
        let running = model
            .records
            .iter()
            .find(|record| record.key == key)
            .unwrap()
            .live_display
            .clone();
        assert_eq!(running, Some(layout.secondary_display.clone()));

        // Dropping the display from the report instead leaves it without a
        // live descriptor, and the engine closes the runtime of such a record
        // and reloads the scene when the display returns.
        let mut dropped = model.clone();
        dropped
            .refresh_connected(primary.clone(), vec![primary.clone()])
            .unwrap();
        assert!(
            !dropped
                .records
                .iter()
                .find(|record| record.key == key)
                .unwrap()
                .should_have_runtime()
        );

        model
            .refresh_connected_keeping(
                primary.clone(),
                vec![primary],
                &[no_pixels(layout.secondary_display.display_id, external.clone())],
            )
            .unwrap();

        let record = model.records.iter().find(|record| record.key == key).unwrap();
        assert!(record.should_have_runtime());
        assert_eq!(record.live_display, running);
        assert!(record.runtime_open);
        assert!(
            model
                .records
                .iter()
                .find(|record| record.key == DisplayKey::Primary)
                .unwrap()
                .runtime_open
        );
    }

    #[test]
    fn transitional_matching_uses_identity_when_the_display_id_changed() {
        let layout = running_layout();
        let external = layout.secondary_display.identity.clone();
        let key = DisplayKey::Identity(external.clone());
        let mut model = layout.model;
        let primary = layout.primary_display;
        let running = model
            .records
            .iter()
            .find(|record| record.key == key)
            .unwrap()
            .live_display
            .clone();

        // The same monitor came back under a new id and has no size yet.
        model
            .refresh_connected_keeping(
                primary.clone(),
                vec![primary],
                &[no_pixels(layout.secondary_display.display_id + 1, external.clone())],
            )
            .unwrap();

        let record = model.records.iter().find(|record| record.key == key).unwrap();
        assert_eq!(record.live_display, running);
        assert!(record.runtime_open);
    }

    #[test]
    fn a_transitional_display_does_not_keep_a_different_display_that_went_away() {
        let layout = running_layout();
        let external = layout.secondary_display.identity.clone();
        let key = DisplayKey::Identity(external.clone());
        let mut model = layout.model;
        let primary = layout.primary_display;
        let unrelated = contract_display(layout.secondary_display.display_id + 1);

        model
            .refresh_connected_keeping(
                primary.clone(),
                vec![primary],
                &[no_pixels(unrelated.display_id, unrelated.identity)],
            )
            .unwrap();

        let record = model.records.iter().find(|record| record.key == key).unwrap();
        assert!(record.live_display.is_none());
        assert!(!record.runtime_open);
    }
}
