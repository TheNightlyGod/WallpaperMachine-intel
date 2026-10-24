// Clean-room implementation from the WallpaperMachine spec r1a-core-engine.md; written without access to the original source.
use std::collections::{HashMap, HashSet};

use crate::{
    EngineError, WallpaperAssignment,
    display::state::{DisplayKey, DisplayRecord, DisplayStateModel},
    engine::{
        DisplaySnapshotEntry, SceneWindowEntry,
        runtime::{SceneRuntime, SceneRuntimeState},
        snapshot::EngineSnapshot,
    },
    project::{SceneDesc, SceneHandle, SceneTemplate},
};

/// Every display slot the engine thread holds, with the handle bookkeeping
/// that lets the host address the scene of a slot by number.
pub struct EngineState {
    pub display_records: Vec<DisplayRuntimeRecord>,
    pub handles_by_display: HashMap<DisplayKey, SceneHandle>,
    pub displays_by_handle: HashMap<SceneHandle, DisplayKey>,
    pub next_handle: u64,
    /// The scene paths each display (by id) may keep parked when its live
    /// scene moves on to another wallpaper. Runtime state, never saved.
    pub parking: HashMap<u32, Vec<String>>,
}

/// One slot: the display model's record plus what only the engine knows.
pub struct DisplayRuntimeRecord {
    pub model: DisplayRecord,
    pub handle: Option<SceneHandle>,
    pub runtime: Option<SceneRuntime>,
    pub last_runtime_state: Option<StoredSceneRuntimeState>,
    /// Scenes this display showed before and keeps loaded and paused, each
    /// with the handle it had while it was live. The indexes name only the
    /// live handle, so a parked scene cannot be addressed until it runs again.
    pub parked: Vec<ParkedRuntime>,
}

/// A scene kept loaded and paused on its display after the display moved on
/// to another wallpaper, so that wallpaper can run again without a load.
pub struct ParkedRuntime {
    pub handle: SceneHandle,
    pub runtime: SceneRuntime,
}

/// What a closed scene leaves behind so the next scene on the slot can pick
/// up where it stopped: its live state and the descriptor it was running.
#[derive(Clone)]
pub struct StoredSceneRuntimeState {
    desc: SceneDesc,
    state: SceneRuntimeState,
}

impl StoredSceneRuntimeState {
    pub fn new(desc: SceneDesc, state: SceneRuntimeState) -> Self {
        Self { desc, state }
    }

    /// The state a scene for `desc` starts with, carried over from the scene
    /// this was remembered from (same wallpaper keeps it, another one takes
    /// the descriptor's own values).
    pub fn runtime_state_for_desc(
        &self,
        desc: &SceneDesc,
    ) -> Result<SceneRuntimeState, EngineError> {
        let mut state = self.state.clone();
        state.inherit_descriptor_transition(&self.desc, desc)?;
        Ok(state)
    }
}

impl DisplayRuntimeRecord {
    fn empty(model: DisplayRecord) -> Self {
        Self { model, handle: None, runtime: None, last_runtime_state: None, parked: Vec::new() }
    }

    /// Whether anything of this slot's state is worth carrying to another slot.
    fn holds_anything(&self) -> bool {
        self.handle.is_some()
            || self.runtime.is_some()
            || self.last_runtime_state.is_some()
            || !self.parked.is_empty()
    }

    pub fn should_have_runtime(&self) -> bool {
        self.model.should_have_runtime()
    }

    pub fn scene_desc(&self) -> Result<Option<SceneDesc>, EngineError> {
        self.model.scene_desc()
    }

    /// The state a scene for `desc` starts with on this slot: the live
    /// scene's, else the remembered one's, else the descriptor's own.
    pub fn runtime_state_for_desc(
        &self,
        desc: &SceneDesc,
    ) -> Result<SceneRuntimeState, EngineError> {
        if let Some(runtime) = &self.runtime {
            return runtime.runtime_state_for_desc(desc);
        }
        match &self.last_runtime_state {
            Some(stored) => stored.runtime_state_for_desc(desc),
            None => SceneRuntimeState::try_from(desc),
        }
    }

    /// Remembers the live scene's state and descriptor; with no live scene the
    /// earlier memory stays as it was.
    pub fn store_runtime_snapshot(&mut self) {
        if let Some(runtime) = &self.runtime {
            self.last_runtime_state =
                Some(StoredSceneRuntimeState::new(runtime.desc.clone(), runtime.runtime_state()));
        }
    }
}

impl EngineState {
    pub fn with_display_model(model: DisplayStateModel) -> Self {
        Self {
            display_records: model.records.into_iter().map(DisplayRuntimeRecord::empty).collect(),
            handles_by_display: HashMap::new(),
            displays_by_handle: HashMap::new(),
            next_handle: 1,
            parking: HashMap::new(),
        }
    }

    /// What readers see: one entry per slot that has a live display, in slot
    /// order. A handle shows only while a scene is alive on the slot, so a
    /// reservation that outlived its scene reads as none.
    pub fn snapshot(&self) -> EngineSnapshot {
        let displays = self
            .display_records
            .iter()
            .filter_map(|record| {
                let desc = record.model.live_display.clone()?;
                let live = record.runtime.as_ref();
                Some(DisplaySnapshotEntry {
                    identity: desc.identity.clone(),
                    desc,
                    handle: live.and(record.handle),
                    accepts_pointer_input: live.is_some_and(SceneRuntime::accepts_pointer_input),
                    paused: live.is_some_and(SceneRuntime::paused),
                    window_active: record.model.window_active,
                    assignment: record.model.assignment.clone(),
                })
            })
            .collect();
        let scenes = self
            .display_records
            .iter()
            .flat_map(|record| {
                let live = record
                    .runtime
                    .as_ref()
                    .zip(record.handle)
                    .map(|(runtime, handle)| SceneWindowEntry::of(runtime, handle, false));
                let parked = record
                    .parked
                    .iter()
                    .map(|parked| SceneWindowEntry::of(&parked.runtime, parked.handle, true));
                live.into_iter().chain(parked)
            })
            .collect();
        EngineSnapshot { displays, scenes }
    }

    /// Whether the display `display_id` may keep a scene of `scene_path`
    /// parked when it moves on.
    pub fn may_park(&self, display_id: u32, scene_path: &str) -> bool {
        self.parking
            .get(&display_id)
            .is_some_and(|paths| paths.iter().any(|path| path == scene_path))
    }

    /// Handles of live scenes whose renderers report that they read system
    /// audio. A record without a runtime has no scene and never counts.
    pub fn audio_requiring_handles(&self) -> std::collections::HashSet<SceneHandle> {
        self.display_records
            .iter()
            .filter_map(|record| {
                let runtime = record.runtime.as_ref()?;
                runtime.requires_audio().then_some(record.handle).flatten()
            })
            .collect()
    }

    /// Whether a presenting scene is waiting for a pointer sample it would not
    /// otherwise get, because the cursor has not moved since its delivery reset.
    pub fn pointer_sample_pending(&self) -> bool {
        self.display_records
            .iter()
            .filter_map(|record| record.runtime.as_ref())
            .any(SceneRuntime::pointer_sample_pending)
    }

    pub fn record_index(&self, key: &DisplayKey) -> Option<usize> {
        self.display_records.iter().position(|record| &record.model.key == key)
    }

    /// The slot of `model` with this key, added empty when there is none.
    #[cfg(test)]
    pub fn ensure_record(&mut self, model: DisplayRecord) -> &mut DisplayRuntimeRecord {
        let index = self.record_index(&model.key).unwrap_or_else(|| {
            self.display_records.push(DisplayRuntimeRecord::empty(model));
            self.display_records.len() - 1
        });
        &mut self.display_records[index]
    }

    /// Replaces the slots by the ones of `model`, moving each live scene with
    /// its physical display. Every slot that should have a scene first takes
    /// the contents of the first earlier slot that held the same display; only
    /// then does each slot left over take the earlier slot with an equal key.
    /// In that order a scene whose slot changed (the old main display's leaving
    /// the primary slot) keeps its runtime and handle instead of being closed
    /// under the key it left. Earlier slots nobody took are kept unless their
    /// key is in the new list (then they are dropped, closing whatever they
    /// still hold).
    pub fn apply_display_model(&mut self, model: &DisplayStateModel) -> Result<(), EngineError> {
        let mut earlier: Vec<Option<DisplayRuntimeRecord>> =
            std::mem::take(&mut self.display_records).into_iter().map(Some).collect();
        let mut taken: Vec<Option<DisplayRuntimeRecord>> =
            std::iter::repeat_with(|| None).take(model.records.len()).collect();

        for (slot, new_model) in taken.iter_mut().zip(&model.records) {
            let Some(display) = new_model
                .should_have_runtime()
                .then_some(new_model.live_display.as_ref())
                .flatten()
            else {
                continue;
            };
            let by_display = earlier.iter().position(|old| {
                old.as_ref().is_some_and(|old| {
                    old.holds_anything()
                        && old
                            .model
                            .live_display
                            .as_ref()
                            .is_some_and(|held| held.is_same_physical_display_as(display))
                })
            });
            *slot = by_display.and_then(|index| earlier[index].take());
        }
        for (slot, new_model) in taken.iter_mut().zip(&model.records) {
            if slot.is_some() {
                continue;
            }
            let by_key = earlier.iter().position(|old| {
                old.as_ref().is_some_and(|old| old.model.key == new_model.key)
            });
            *slot = by_key.and_then(|index| earlier[index].take());
        }

        let mut next = Vec::with_capacity(model.records.len());
        for (slot, new_model) in taken.into_iter().zip(&model.records) {
            let mut record = DisplayRuntimeRecord::empty(new_model.clone());
            if let Some(taken) = slot {
                record.handle = taken.handle;
                record.runtime = taken.runtime;
                record.last_runtime_state = taken.last_runtime_state;
                record.parked = taken.parked;
            }
            next.push(record);
        }

        let new_keys: HashSet<&DisplayKey> = model.records.iter().map(|record| &record.key).collect();
        next.extend(
            earlier
                .into_iter()
                .flatten()
                .filter(|slot| !new_keys.contains(&slot.model.key)),
        );

        self.display_records = next;
        self.rebuild_handle_indexes();
        Ok(())
    }

    fn rebuild_handle_indexes(&mut self) {
        self.handles_by_display.clear();
        self.displays_by_handle.clear();
        for record in &self.display_records {
            if let Some(handle) = record.handle {
                self.handles_by_display.insert(record.model.key.clone(), handle);
                self.displays_by_handle.insert(handle, record.model.key.clone());
            }
        }
    }

    /// The handle of `key`, issuing the next number the first time.
    pub fn reserve_handle_for_key(&mut self, key: DisplayKey) -> SceneHandle {
        if let Some(handle) = self.handles_by_display.get(&key) {
            return *handle;
        }
        let handle = SceneHandle::new(self.next_handle);
        self.next_handle = self.next_handle.saturating_add(1);
        self.handles_by_display.insert(key.clone(), handle);
        self.displays_by_handle.insert(handle, key);
        handle
    }

    /// Makes the indexes name exactly `handle` for `key`, or nothing.
    pub fn sync_handle_reservation(&mut self, key: DisplayKey, handle: Option<SceneHandle>) {
        if let Some(earlier) = self.handles_by_display.remove(&key) {
            self.displays_by_handle.remove(&earlier);
        }
        if let Some(handle) = handle {
            self.handles_by_display.insert(key.clone(), handle);
            self.displays_by_handle.insert(handle, key);
        }
    }

    /// The slot a handle names, or why it names none.
    fn slot_of(&self, handle: SceneHandle) -> Result<usize, EngineError> {
        let key = self.displays_by_handle.get(&handle).ok_or_else(|| {
            EngineError::InvalidInput(format!("unknown scene handle {}", handle.raw()))
        })?;
        self.record_index(key).ok_or_else(|| {
            EngineError::Platform(format!(
                "scene handle {} names display {}, which no longer exists",
                handle.raw(),
                key.key_label()
            ))
        })
    }

    fn not_active(handle: SceneHandle) -> EngineError {
        EngineError::InvalidInput(format!("scene handle {} is not active", handle.raw()))
    }

    pub fn scene_mut(&mut self, handle: SceneHandle) -> Result<&mut SceneRuntime, EngineError> {
        let index = self.slot_of(handle)?;
        self.display_records[index]
            .runtime
            .as_mut()
            .ok_or_else(|| Self::not_active(handle))
    }

    /// Notes that the scene behind `handle` is open and what it looks like
    /// now: the slot keeps its handle, remembers the state and descriptor,
    /// and a direct assignment follows the live descriptor.
    pub fn record_runtime_state(&mut self, handle: SceneHandle) -> Result<(), EngineError> {
        let index = self.slot_of(handle)?;
        let record = &mut self.display_records[index];
        let Some(runtime) = record.runtime.as_ref() else {
            return Err(Self::not_active(handle));
        };
        let desc = runtime.desc.clone();
        record.handle = Some(handle);
        record.store_runtime_snapshot();
        record.model.runtime_open = true;
        // The host compares templates to decide what needs reconciling, so a
        // direct assignment follows what the scene runs now; a mirror does not.
        if let Some(WallpaperAssignment::Direct(template)) = record.model.assignment.as_mut() {
            *template = SceneTemplate::from_scene_desc(&desc);
        }
        Ok(())
    }

    /// Closes every scene, the parked ones included, and forgets every handle,
    /// keeping the slots, their window flags, assignments and remembered state
    /// (the live scene's, never a parked one's). The counter is not
    /// rewound. Every scene is released even when one fails to close; the
    /// first error comes back afterwards.
    pub fn close_all(&mut self) -> Result<(), EngineError> {
        self.close_all_with(SceneRuntime::close)
    }

    fn close_all_with(
        &mut self,
        mut close: impl FnMut(&mut SceneRuntime) -> Result<(), EngineError>,
    ) -> Result<(), EngineError> {
        self.handles_by_display = HashMap::new();
        self.displays_by_handle = HashMap::new();
        let scenes: Vec<SceneRuntime> = self
            .display_records
            .iter_mut()
            .flat_map(|record| {
                record.handle = None;
                record.model.runtime_open = false;
                // The snapshot reads the live scene, so it has to come before the
                // runtime is taken out of the record.
                record.store_runtime_snapshot();
                let parked = std::mem::take(&mut record.parked).into_iter().map(|parked| parked.runtime);
                record.runtime.take().into_iter().chain(parked)
            })
            .collect();
        // Every scene is closed even after a failure; only the first error is kept.
        let mut first_error = None;
        for mut scene in scenes {
            let outcome = close(&mut scene);
            first_error = first_error.or(outcome.err());
        }
        first_error.map_or(Ok(()), Err)
    }
}

impl Default for EngineState {
    /// The state of the default configuration: one primary slot with its
    /// window active, no assignment and no live display.
    fn default() -> Self {
        Self::with_display_model(DisplayStateModel {
            records: vec![DisplayRecord {
                key: DisplayKey::Primary,
                live_display: None,
                assignment: None,
                window_active: true,
                runtime_open: false,
                primary_inheritance_consumed: false,
                bound_to_display: false,
            }],
        })
    }
}

#[cfg(test)]
mod tests {
    use super::EngineState;
    use kameo::actor::Spawn;
    use crate::{
        WallpaperAssignment,
        display::state::{DisplayKey, DisplayRecord, DisplayStateModel},
        project::{ScalingMode, SceneDesc, SceneFraming, SceneTemplate},
    };



    #[tokio::test(flavor = "current_thread")]
    #[allow(clippy::too_many_lines)]
    async fn display_model_update_transfers_handles_by_physical_display() {
        // CLEANROOM ET58
        let mut first = cleanroom_et60();
        first.display.display_id = 87;
        first.display.identity.uuid = Some("physical-orchid".into());
        let mut second = first.clone();
        second.display.display_id = 126;
        second.display.identity.uuid = Some("physical-cobalt".into());
        let (mut state, a) = cleanroom_et59(&first, WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&first)), &first);
        let prepared = crate::engine::actor::EngineActor::prepare();
        let key_b = DisplayKey::LiveDisplayId(126);
        let model_b = DisplayRecord { key: key_b.clone(), live_display: Some(second.display.clone()), assignment: Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&second))), window_active: true, runtime_open: true, primary_inheritance_consumed: true, bound_to_display: false };
        state.ensure_record(model_b.clone());
        let b = state.reserve_handle_for_key(key_b);
        let runtime = crate::engine::runtime::SceneRuntime::windowless_for_test(b, &second, &crate::engine::runtime::SceneRuntimeState::try_from(&second).unwrap(), prepared.actor_ref().downgrade()).unwrap();
        state.display_records[1].handle = Some(b);
        state.display_records[1].runtime = Some(runtime);
        state.record_runtime_state(a).unwrap();
        state.record_runtime_state(b).unwrap();
        let mut new_primary = model_b;
        new_primary.key = DisplayKey::Primary;
        new_primary.live_display.as_mut().unwrap().display_id = 203;
        new_primary.live_display.as_mut().unwrap().x = -905;
        let mut new_secondary = state.display_records[0].model.clone();
        new_secondary.key = DisplayKey::LiveDisplayId(87);
        state.apply_display_model(&DisplayStateModel { records: vec![new_primary, new_secondary] }).unwrap();
        assert_eq!(state.display_records.len(), 2);
        assert_eq!(state.display_records[0].handle, Some(b));
        assert_eq!(state.display_records[1].handle, Some(a));
        assert_eq!(state.display_records[0].runtime.as_ref().unwrap().desc.scene_path, second.scene_path);
        assert_eq!(state.display_records[1].runtime.as_ref().unwrap().desc.display.identity, first.display.identity);
        assert_eq!(state.display_records[0].last_runtime_state.as_ref().unwrap().desc.display.display_id, 126);
        assert_eq!(state.display_records[1].last_runtime_state.as_ref().unwrap().desc.display.display_id, 87);
        assert_eq!(state.displays_by_handle.get(&b), Some(&DisplayKey::Primary));
        assert_eq!(state.handles_by_display.get(&DisplayKey::LiveDisplayId(87)), Some(&a));
        assert!(state.scene_mut(a).is_ok());
        assert!(state.scene_mut(b).is_ok());
    }

    fn cleanroom_et59(
        original: &SceneDesc,
        assignment: WallpaperAssignment,
        live: &SceneDesc,
    ) -> (EngineState, crate::project::SceneHandle) {
        // CLEANROOM ET59: a windowless renderer on a real engine slot.
        use kameo::actor::Spawn;
        let mut state = EngineState::with_display_model(DisplayStateModel { records: vec![DisplayRecord {
            key: DisplayKey::Primary,
            live_display: Some(original.display.clone()),
            assignment: Some(assignment),
            window_active: true,
            runtime_open: false,
            primary_inheritance_consumed: true,
            bound_to_display: false,
        }] });
        let handle = state.reserve_handle_for_key(DisplayKey::Primary);
        let prepared = crate::engine::actor::EngineActor::prepare();
        let runtime = crate::engine::runtime::SceneRuntime::windowless_for_test(handle, live,
            &crate::engine::runtime::SceneRuntimeState::try_from(live).unwrap(),
            prepared.actor_ref().downgrade()).unwrap();
        state.display_records[0].handle = Some(handle);
        state.display_records[0].runtime = Some(runtime);
        (state, handle)
    }

    fn cleanroom_et60() -> SceneDesc {
        // CLEANROOM ET60: inert identifiers, no asset access.
        SceneDesc::builder(crate::DisplayDesc::new(203, -613, 137, 2496, 1408, 2.0), "/virtual/orchid/scene.json")
            .fps(53).build().unwrap()
    }

    #[tokio::test(flavor = "current_thread")]
    async fn runtime_record_syncs_direct_assignment_from_live_descriptor() {
        // CLEANROOM ET61
        let original = cleanroom_et60();
        let mut live = original.clone();
        live.scaling_mode = ScalingMode::Stretch;
        live.scaling_factor = 1.65;
        let (mut state, handle) = cleanroom_et59(&original, WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&original)), &live);
        state.record_runtime_state(handle).unwrap();
        let record = &state.display_records[0];
        assert_eq!(record.handle, Some(handle));
        assert!(record.model.runtime_open);
        assert_eq!(record.scene_desc().unwrap().unwrap().scaling_mode, ScalingMode::Stretch);
        assert_eq!(record.scene_desc().unwrap().unwrap().scaling_factor, 1.65);
        assert_eq!(record.last_runtime_state.as_ref().unwrap().state.scaling_mode, ScalingMode::Stretch);
        assert_eq!(record.last_runtime_state.as_ref().unwrap().desc, live);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn runtime_record_keeps_a_live_framing_in_its_direct_assignment() {
        let original = cleanroom_et60();
        let moved = SceneFraming { pan_x: 0.2, pan_y: 0.8 };
        let mut live = original.clone();
        live.framing = moved;
        let (mut state, handle) = cleanroom_et59(
            &original,
            WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&original)),
            &live,
        );

        state.record_runtime_state(handle).expect("the scene is live");

        // The bridge compares these templates to decide what needs reconciling,
        // and the scene a later reconcile builds from them must keep the position.
        let record = &state.display_records[0];
        let Some(WallpaperAssignment::Direct(template)) = record.model.assignment.as_ref() else {
            panic!("the direct assignment should remain");
        };
        assert_eq!(template.framing, moved);
        assert_eq!(
            record
                .scene_desc()
                .expect("scene should build")
                .expect("assigned scene should exist")
                .framing,
            moved
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn runtime_record_leaves_a_mirror_assignment_alone() {
        let original = cleanroom_et60();
        let mut live = original.clone();
        live.scaling_mode = ScalingMode::Stretch;
        let mirror = WallpaperAssignment::Mirror(crate::DisplaySelector::Primary);
        let (mut state, handle) = cleanroom_et59(&original, mirror.clone(), &live);

        state.record_runtime_state(handle).expect("the scene is live");

        assert_eq!(state.display_records[0].model.assignment, Some(mirror));
    }

    #[test]
    fn snapshot_hides_reserved_handle_without_live_runtime() {
        // CLEANROOM ET62
        let desc = cleanroom_et60();
        let mut state = EngineState::default();
        state.display_records[0].model.live_display = Some(desc.display.clone());
        state.display_records[0].model.assignment = Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&desc)));
        let handle = state.reserve_handle_for_key(DisplayKey::Primary);
        state.display_records[0].handle = Some(handle);
        let snapshot = state.snapshot();
        assert_eq!(snapshot.displays.len(), 1);
        let entry = &snapshot.displays[0];
        assert_eq!(entry.desc, desc.display);
        assert_eq!(entry.assignment, state.display_records[0].model.assignment);
        assert_eq!(entry.handle, None);
        assert!(!entry.paused);
        assert!(!entry.accepts_pointer_input);
        assert!(matches!(state.scene_mut(handle), Err(crate::EngineError::InvalidInput(text)) if text.contains("is not active")));
        assert_eq!(state.reserve_handle_for_key(DisplayKey::Primary), handle);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn close_all_attempts_every_scene_after_a_refusal_and_preserves_the_first_error() {
        let desc = cleanroom_et60();
        let (mut state, _) = cleanroom_et59(&desc, WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&desc)), &desc);
        let prepared = crate::engine::actor::EngineActor::prepare();
        for id in [126, 87] {
            let mut next = desc.clone();
            next.display.display_id = id;
            let key = DisplayKey::LiveDisplayId(id);
            state.ensure_record(DisplayRecord { key: key.clone(), live_display: Some(next.display.clone()), assignment: Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(&next))), window_active: true, runtime_open: true, primary_inheritance_consumed: true, bound_to_display: false });
            let handle = state.reserve_handle_for_key(key.clone());
            let index = state.record_index(&key).unwrap();
            state.display_records[index].handle = Some(handle);
            state.display_records[index].runtime = Some(crate::engine::runtime::SceneRuntime::windowless_for_test(handle, &next, &crate::engine::runtime::SceneRuntimeState::try_from(&next).unwrap(), prepared.actor_ref().downgrade()).unwrap());
        }
        let mut attempted = Vec::new();
        let result = state.close_all_with(|runtime| {
            attempted.push(runtime.display_id());
            runtime.close()?;
            match runtime.display_id() {
                203 => Err(crate::EngineError::Platform("first close refusal".into())),
                126 => Err(crate::EngineError::Render("second close refusal".into())),
                _ => Ok(()),
            }
        });
        assert!(matches!(result, Err(crate::EngineError::Platform(text)) if text == "first close refusal"));
        assert_eq!(attempted, vec![203, 126, 87]);
        assert!(state.handles_by_display.is_empty() && state.displays_by_handle.is_empty());
        assert!(state.display_records.iter().all(|r| r.handle.is_none() && r.runtime.is_none() && !r.model.runtime_open && r.last_runtime_state.is_some()));
        assert_eq!(state.next_handle, 4);
    }

    #[test]
    fn handles_are_issued_in_order_kept_per_key_and_never_wrap() {
        let mut state = EngineState::default();
        let primary = state.reserve_handle_for_key(DisplayKey::Primary);
        let other = state.reserve_handle_for_key(DisplayKey::LiveDisplayId(5));

        assert_eq!((primary.raw(), other.raw()), (1, 2));
        assert_eq!(state.reserve_handle_for_key(DisplayKey::Primary), primary);
        assert_eq!(state.next_handle, 3);

        state.next_handle = u64::MAX;
        let last = state.reserve_handle_for_key(DisplayKey::LiveDisplayId(6));
        let again = state.reserve_handle_for_key(DisplayKey::LiveDisplayId(7));
        assert_eq!(last.raw(), u64::MAX);
        assert_eq!(again.raw(), u64::MAX, "the counter saturates instead of wrapping to zero");
    }

    #[test]
    fn syncing_a_reservation_replaces_both_indexes_or_removes_them() {
        let mut state = EngineState::default();
        let first = state.reserve_handle_for_key(DisplayKey::Primary);

        state.sync_handle_reservation(DisplayKey::Primary, Some(crate::project::SceneHandle::new(40)));
        assert!(!state.displays_by_handle.contains_key(&first));
        assert_eq!(
            state.handles_by_display.get(&DisplayKey::Primary),
            Some(&crate::project::SceneHandle::new(40))
        );

        state.sync_handle_reservation(DisplayKey::Primary, None);
        assert!(state.handles_by_display.is_empty());
        assert!(state.displays_by_handle.is_empty());
    }

    #[test]
    fn a_handle_lookup_fails_as_unknown_then_as_a_missing_slot_then_as_not_active() {
        let mut state = EngineState::default();
        let unknown = state.scene_mut(crate::project::SceneHandle::new(99)).err();
        assert!(matches!(&unknown, Some(crate::EngineError::InvalidInput(text))
            if text.contains("unknown scene handle") && text.contains("99")));

        let gone = crate::project::SceneHandle::new(98);
        state.displays_by_handle.insert(gone, DisplayKey::LiveDisplayId(5));
        let missing = state.scene_mut(gone).err();
        assert!(matches!(&missing, Some(crate::EngineError::Platform(text)) if text.contains("98")));

        let reserved = state.reserve_handle_for_key(DisplayKey::Primary);
        let idle = state.scene_mut(reserved).err();
        assert!(matches!(&idle, Some(crate::EngineError::InvalidInput(text))
            if text.contains("is not active") && text.contains(&reserved.raw().to_string())));
        assert!(matches!(
            state.record_runtime_state(reserved),
            Err(crate::EngineError::InvalidInput(_))
        ));
    }

    #[test]
    fn an_earlier_slot_nobody_took_survives_unless_its_key_is_in_the_new_model() {
        let mut state = EngineState::default();
        let kept = state.reserve_handle_for_key(DisplayKey::LiveDisplayId(8));
        state.ensure_record(DisplayRecord {
            key: DisplayKey::LiveDisplayId(8),
            live_display: None,
            assignment: None,
            window_active: false,
            runtime_open: false,
            primary_inheritance_consumed: false,
            bound_to_display: false,
        });
        state.display_records[1].handle = Some(kept);

        // The new model has only the primary slot: slot 8 is not in it and stays.
        let model = DisplayStateModel { records: vec![state.display_records[0].model.clone()] };
        state.apply_display_model(&model).unwrap();

        assert_eq!(state.display_records.len(), 2);
        assert_eq!(state.display_records[1].model.key, DisplayKey::LiveDisplayId(8));
        assert_eq!(state.handles_by_display.get(&DisplayKey::LiveDisplayId(8)), Some(&kept));
    }
}
