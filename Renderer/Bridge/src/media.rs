//! Replay store for the system media state the host pushes in.
//!
//! The bridge does not read the system player and does not deliver anything to
//! a page. The host's media provider owns both ends; this only remembers the
//! last event of each kind so a page that loads after the fact can be brought
//! up to date instead of sitting blank until the next system change.
//!
//! Event bodies are stored verbatim. The payload contract belongs to the host,
//! so the only thing validated here is the `type` tag, which is exactly the
//! vocabulary `wallpaper_core::media::integration::MediaIntegrationEvent`
//! serializes.

use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex, MutexGuard},
};

use serde_json::Value;

use crate::api::BridgeError;

/// Which listener an event feeds.
///
/// Ordering is the replay order: what is playing and what it is are useful
/// before its artwork, and a timeline without a track is meaningless.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum MediaSlot {
    Status,
    Properties,
    Thumbnail,
    Playback,
    Timeline,
}

#[derive(Debug, Default)]
struct SystemMediaState {
    /// Highest generation accepted so far. Only ever increases.
    generation: u64,
    slots: BTreeMap<MediaSlot, Value>,
}

/// Process-wide last-known system media state.
///
/// There is one system player, so this is neither per wallpaper nor per
/// display. Which wallpapers may see it is a separate decision, held in each
/// wallpaper's own configuration.
#[derive(Clone, Debug, Default)]
pub struct SystemMediaStore {
    state: Arc<Mutex<SystemMediaState>>,
}

/// What [`SystemMediaStore::submit`] did with an event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaSubmission {
    /// Stored; it is now part of what a late page is replayed.
    Accepted,
    /// Dropped: it describes an older state than one already stored. A host
    /// produces these legitimately, because artwork and timeline are fetched
    /// asynchronously and can arrive after the track has already changed.
    Stale,
}

impl SystemMediaStore {
    /// Records one media event, newest wins.
    ///
    /// A `generation` in the payload orders submissions. It is optional; an
    /// event without one is treated as newer than everything stored, which is
    /// right for a provider that pushes synchronously and never reorders.
    ///
    /// # Errors
    ///
    /// Returns an error when `json` is not a JSON object or its `type` is not
    /// one of the five media event tags. Nothing is stored in that case.
    pub fn submit(&self, json: &str) -> Result<MediaSubmission, BridgeError> {
        let value: Value =
            serde_json::from_str(json).map_err(|error| BridgeError::invalid_input(error.to_string()))?;
        let object = value
            .as_object()
            .ok_or_else(|| BridgeError::invalid_input("media event must be a JSON object"))?;
        let tag = object
            .get("type")
            .and_then(Value::as_str)
            .ok_or_else(|| BridgeError::invalid_input("media event has no \"type\""))?;
        let slot = match tag {
            "mediaStatusChanged" => MediaSlot::Status,
            "mediaPropertiesChanged" => MediaSlot::Properties,
            "mediaThumbnailChanged" => MediaSlot::Thumbnail,
            "mediaPlaybackChanged" => MediaSlot::Playback,
            "mediaTimelineChanged" => MediaSlot::Timeline,
            other => {
                return Err(BridgeError::invalid_input(format!(
                    "unknown media event type \"{other}\""
                )));
            }
        };
        let generation = object.get("generation").and_then(Value::as_u64);

        let mut state = self.lock();
        match generation {
            Some(generation) if generation < state.generation => {
                log::debug!(
                    "dropped {tag} at generation {generation}, already at {}",
                    state.generation
                );
                return Ok(MediaSubmission::Stale);
            }
            Some(generation) => state.generation = generation,
            None => state.generation = state.generation.saturating_add(1),
        }
        let _ = state.slots.insert(slot, value);

        Ok(MediaSubmission::Accepted)
    }

    /// Every retained event as a JSON array, in replay order.
    ///
    /// `None` until something has been submitted, so a host can tell "nothing
    /// is known yet" from "known to be stopped".
    #[must_use]
    pub fn current_state_json(&self) -> Option<String> {
        let state = self.lock();
        if state.slots.is_empty() {
            return None;
        }

        let events: Vec<&Value> = state.slots.values().collect();
        serde_json::to_string(&events).ok()
    }

    /// A panic while holding this lock cannot corrupt a plain JSON map, and
    /// refusing to serve media state afterwards would blank every page's
    /// integration until the next system change.
    fn lock(&self) -> MutexGuard<'_, SystemMediaState> {
        self.state.lock().unwrap_or_else(|poisoned| {
            self.state.clear_poison();
            poisoned.into_inner()
        })
    }
}
