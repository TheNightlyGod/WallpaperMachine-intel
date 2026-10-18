use serde::{Serialize, Serializer};

/// Playback state as Wallpaper Engine media scripts read it from
/// `event.state`: `PLAYBACK_STOPPED` 0, `PLAYBACK_PLAYING` 1,
/// `PLAYBACK_PAUSED` 2. The discriminants are those numbers and are what
/// serializes; a host's own numbering is mapped to these variants by name where
/// the host's value enters (see `BridgeMediaSnapshot::into_state`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum MediaPlaybackState {
    /// No active player is available.
    Stopped = 0,
    /// Audio is currently progressing.
    Playing = 1,
    /// A player is active but playback is paused.
    Paused = 2,
}

impl Serialize for MediaPlaybackState {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_u8(*self as u8)
    }
}

/// Song metadata exposed to Wallpaper Engine media integration callbacks.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct MediaProperties {
    #[serde(rename = "albumTitle")]
    pub album_title: Option<String>,
    pub artist: Option<String>,
    pub title: Option<String>,
}

/// RGBA artwork texture payload for the renderer-owned `$mediaThumbnail`.
/// A zero-by-zero image with no bytes explicitly clears both cover slots.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaThumbnailRgba {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Incremental media-provider output from one system polling pass.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MediaPollResult {
    pub events: Vec<MediaIntegrationEvent>,
    pub artwork: Option<MediaThumbnailRgba>,
}

impl MediaPollResult {
    pub fn changed_events<'a>(&'a self, previous: Option<&'a Self>) -> impl Iterator<Item = &'a MediaIntegrationEvent> {
        let artwork_changed = self.artwork.is_some()
            && previous.and_then(|state| state.artwork.as_ref()) != self.artwork.as_ref();
        self.events.iter().filter(move |event| {
            (artwork_changed && matches!(event, MediaIntegrationEvent::ThumbnailChanged { .. }))
                || !previous.is_some_and(|state| state.events.contains(event))
        })
    }
}

#[cfg(test)]
mod snapshot_tests {
    use super::*;

    #[test]
    fn playback_state_serializes_as_the_numbers_scripts_compare_against() {
        let number = |state| serde_json::to_string(&state).unwrap();
        assert_eq!(number(MediaPlaybackState::Stopped), "0");
        assert_eq!(number(MediaPlaybackState::Playing), "1");
        assert_eq!(number(MediaPlaybackState::Paused), "2");
    }

    #[test]
    fn playback_event_carries_the_script_number_not_a_host_numbering() {
        let json = |state| MediaIntegrationEvent::PlaybackChanged { state }.to_json().unwrap();
        assert_eq!(json(MediaPlaybackState::Playing), r#"{"type":"mediaPlaybackChanged","state":1}"#);
        assert_eq!(json(MediaPlaybackState::Paused), r#"{"type":"mediaPlaybackChanged","state":2}"#);
        assert_eq!(json(MediaPlaybackState::Stopped), r#"{"type":"mediaPlaybackChanged","state":0}"#);
    }

    #[test]
    fn changed_cover_replays_thumbnail_event_even_when_colors_match() {
        let first = MediaPollResult {
            events: vec![MediaIntegrationEvent::ThumbnailChanged {
                has_thumbnail: true, primary_color: [0.0; 3], text_color: [1.0; 3],
            }],
            artwork: Some(MediaThumbnailRgba::new(1, 1, vec![255, 0, 0, 255]).unwrap()),
        };
        let mut second = first.clone();
        second.artwork.as_mut().unwrap().rgba = vec![0, 255, 0, 255];
        assert_eq!(first.changed_events(None).count(), 1);
        assert_eq!(first.changed_events(Some(&first)).count(), 0);
        assert_eq!(second.changed_events(Some(&first)).count(), 1);
        assert_eq!(second.changed_events(Some(&second)).count(), 0);
    }

    #[test]
    fn empty_artwork_is_an_explicit_clear_and_partial_images_are_rejected() {
        let clear = MediaThumbnailRgba::new(0, 0, Vec::new()).unwrap();
        assert_eq!((clear.width, clear.height, clear.rgba.len()), (0, 0, 0));
        assert!(MediaThumbnailRgba::new(0, 1, Vec::new()).is_err());
        assert!(MediaThumbnailRgba::new(1, 0, Vec::new()).is_err());
        assert!(MediaThumbnailRgba::new(0, 0, vec![0; 4]).is_err());
        assert!(MediaThumbnailRgba::new(1, 1, Vec::new()).is_err());
        assert!(MediaThumbnailRgba::new(1, 1, vec![0; 4]).is_ok());
    }

    #[test]
    fn clear_replaces_cached_cover_and_is_replayed_only_when_it_changes() {
        let covered = MediaPollResult {
            events: vec![MediaIntegrationEvent::ThumbnailChanged {
                has_thumbnail: true, primary_color: [0.0; 3], text_color: [1.0; 3],
            }],
            artwork: Some(MediaThumbnailRgba::new(1, 1, vec![20, 40, 60, 255]).unwrap()),
        };
        let clear = MediaPollResult {
            events: vec![MediaIntegrationEvent::ThumbnailChanged {
                has_thumbnail: false, primary_color: [0.0; 3], text_color: [1.0; 3],
            }],
            artwork: Some(MediaThumbnailRgba::new(0, 0, Vec::new()).unwrap()),
        };
        assert_eq!(clear.changed_events(Some(&covered)).count(), 1);
        assert_eq!(clear.changed_events(Some(&clear)).count(), 0);
        assert_eq!(clear.changed_events(None).count(), 1);
        assert_eq!(covered.changed_events(Some(&clear)).count(), 1);
    }
}

impl MediaThumbnailRgba {
    /// # Errors
    ///
    /// Returns an error for a partial clear or a nonempty image whose RGBA
    /// payload length does not equal `width * height * 4`.
    pub fn new(width: u32, height: u32, rgba: Vec<u8>) -> Result<Self, &'static str> {
        if width == 0 && height == 0 && rgba.is_empty() {
            return Ok(Self { width, height, rgba });
        }
        if width == 0 || height == 0 {
            return Err("media thumbnail dimensions must be non-zero");
        }
        let expected = (width as usize).checked_mul(height as usize)
            .and_then(|pixels| pixels.checked_mul(4))
            .ok_or("media thumbnail dimensions exceed the supported payload size")?;
        if rgba.len() != expected {
            return Err("media thumbnail RGBA payload length must equal width * height * 4");
        }
        Ok(Self {
            width,
            height,
            rgba,
        })
    }
}

/// Media integration event serialized into Wallpaper Engine's JavaScript API.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "type")]
pub enum MediaIntegrationEvent {
    #[serde(rename = "mediaStatusChanged")]
    StatusChanged { enabled: bool },
    #[serde(rename = "mediaPlaybackChanged")]
    PlaybackChanged { state: MediaPlaybackState },
    #[serde(rename = "mediaPropertiesChanged")]
    PropertiesChanged(MediaProperties),
    #[serde(rename = "mediaTimelineChanged")]
    TimelineChanged { duration: f64, position: f64 },
    #[serde(rename = "mediaThumbnailChanged")]
    ThumbnailChanged {
        #[serde(rename = "hasThumbnail")]
        has_thumbnail: bool,
        #[serde(rename = "primaryColor")]
        primary_color: [f32; 3],
        #[serde(rename = "textColor")]
        text_color: [f32; 3],
    },
}

impl MediaIntegrationEvent {
    /// # Errors
    ///
    /// Returns an error if serialization fails.
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }
}
