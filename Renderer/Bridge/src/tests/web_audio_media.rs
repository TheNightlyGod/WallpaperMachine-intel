//! Web audio consumers, system media replay, and scene optimisation.
//!
//! Three things matter here. A web page consumes system audio without ever
//! owning a renderer scene, so the capture tap has to open and close on
//! something other than scene handles — and mute, which is a different control
//! entirely, must not close it. System media state is remembered so a page that
//! loads late can be caught up, which is worthless if a slow artwork fetch can
//! overwrite the track that replaced it. And the scene optimisation the user
//! can switch off has to survive a restart and reach the renderer.

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, WallpaperAssignment,
    project::{SceneHandle, SceneTemplate},
};

use crate::{
    api::{BridgeBuilder, WallpaperBridge},
    engine::FakeEngineFacade,
};

fn display_snapshot(display_id: u32) -> DisplaySnapshotEntry {
    let desc =
        DisplayDesc::with_identity(display_id, DisplayIdentity::default(), 0, 0, 1920, 1080, 1.0)
            .with_refresh_rate(60);
    DisplaySnapshotEntry {
        identity: DisplayIdentity::default(),
        desc,
        // A web wallpaper is rendered by the host, so its display has no scene
        // handle. That absence is the whole point of these tests.
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

#[tokio::test]
async fn scene_media_requires_consent_and_clears_on_disable() {
    use crate::api::BridgeMediaSnapshot;
    let engine = FakeEngineFacade::default();
    let mut display = display_snapshot(7);
    display.handle = Some(wallpaper_core::project::SceneHandle::new(7));
    engine.set_snapshot(vec![display]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default()).build().unwrap();
    bridge.inject_scene_project_for_test("301", "Scene",
        r#"{"type":"scene","title":"Scene","file":"scene.json"}"#).await;
    bridge.set_media_integration_enabled("301".into(), false).await.unwrap();
    bridge.set_display_config_enabled("301".into(), "7".into(), true).await.unwrap();
    bridge.apply_wallpaper_options("301".into(), true).await.unwrap();
    let snapshot = BridgeMediaSnapshot { title: "Track".into(), playback_state: 0, ..Default::default() };
    bridge.update_scene_media("301".into(), snapshot.clone()).await.unwrap();
    assert!(engine.media_calls().is_empty());
    assert!(bridge.scene_media_wallpaper_ids().await.unwrap().is_empty());
    bridge.set_media_integration_enabled("301".into(), true).await.unwrap();
    assert_eq!(bridge.scene_media_wallpaper_ids().await.unwrap(), vec!["301"]);
    bridge.update_scene_media("301".into(), snapshot.clone()).await.unwrap();
    assert_eq!(engine.media_calls().len(), 1);
    bridge.set_media_integration_enabled("301".into(), false).await.unwrap();
    let calls = engine.media_calls();
    assert!(!calls.last().unwrap().1);
    let cleared = calls.last().unwrap().2.artwork.as_ref().unwrap();
    assert_eq!((cleared.width, cleared.height, cleared.rgba.len()), (0, 0, 0));
    bridge.update_scene_media("301".into(), snapshot).await.unwrap();
    assert_eq!(engine.media_calls().len(), calls.len());
}

#[test]
fn scene_media_rejects_invalid_artwork_and_timeline() {
    use crate::api::BridgeMediaSnapshot;
    let cleared = BridgeMediaSnapshot::default().into_state().unwrap().artwork.unwrap();
    assert_eq!((cleared.width, cleared.height, cleared.rgba.len()), (0, 0, 0));
    for (width, height) in [(0, 1), (1, 0), (1, 1), (513, 0)] {
        assert!(BridgeMediaSnapshot { artwork_width: width, artwork_height: height,
            ..Default::default() }.into_state().is_err());
    }
    assert!(BridgeMediaSnapshot { duration: f64::NAN, ..Default::default() }.into_state().is_err());
    assert!(BridgeMediaSnapshot { playback_state: 3, ..Default::default() }.into_state().is_err());
    assert!(BridgeMediaSnapshot { artwork_width: 1024, artwork_height: 1024,
        artwork_rgba: vec![1], ..Default::default() }.into_state().is_err());
    assert!(BridgeMediaSnapshot { artwork_width: 2, artwork_height: 2,
        artwork_rgba: vec![1], ..Default::default() }.into_state().is_err());
}

/// The host's playback numbering (0 playing, 1 paused, 2 stopped, as
/// `BridgeMediaSnapshot::playback_state` documents) is mapped by name; what the
/// scene's scripts are sent is Wallpaper Engine's own numbering.
#[test]
fn scene_media_playback_reaches_scripts_in_wallpaper_engines_numbers() {
    use crate::api::BridgeMediaSnapshot;
    let sent = |host_state: u8| {
        let state = BridgeMediaSnapshot { playback_state: host_state, ..Default::default() }
            .into_state()
            .unwrap();
        let playback = state
            .events
            .iter()
            .find(|event| matches!(event, wallpaper_core::media::MediaIntegrationEvent::PlaybackChanged { .. }))
            .unwrap();
        let json: serde_json::Value = serde_json::from_str(&playback.to_json().unwrap()).unwrap();
        json["state"].as_u64().unwrap()
    };
    assert_eq!(sent(0), 1, "host playing is PLAYBACK_PLAYING");
    assert_eq!(sent(1), 2, "host paused is PLAYBACK_PAUSED");
    assert_eq!(sent(2), 0, "host stopped is PLAYBACK_STOPPED");
}

/// One web wallpaper committed to display 7, with audio response left at its
/// default of on.
async fn web_bridge(engine: &FakeEngineFacade) -> WallpaperBridge {
    engine.set_snapshot(vec![display_snapshot(7)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_project_for_test(
            "300",
            "Web",
            r#"{"type":"web","title":"Web","file":"index.html","description":""}"#,
        )
        .await;
    bridge
        .set_display_config_enabled("300".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("300".into(), true).await.unwrap();
    bridge
}

fn tap_open(engine: &FakeEngineFacade) -> bool {
    tap_open_for_scenes(engine, &[])
}

pub(super) fn tap_open_for_scenes(engine: &FakeEngineFacade, scenes: &[SceneHandle]) -> bool {
    use std::sync::Arc;
    use wallpaper_core::media::audio::{
        AudioCaptureBackend, AudioCaptureController, AudioCaptureError, AudioFrameConsumer,
        InterleavedStereoF32, MonoPcmF32,
    };

    struct Consumer;
    impl AudioFrameConsumer for Consumer {
        fn submit_audio_frames(&self, _: InterleavedStereoF32<'_>) -> Result<(), AudioCaptureError> {
            Ok(())
        }
        fn submit_mono_audio_frames(&self, _: MonoPcmF32<'_>) -> Result<(), AudioCaptureError> {
            Ok(())
        }
    }
    #[derive(Default)]
    struct Backend { authorized: bool, running: bool }
    impl AudioCaptureBackend for Backend {
        fn has_permission(&self) -> Result<bool, AudioCaptureError> { Ok(self.authorized) }
        fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
            self.authorized = true;
            Ok(true)
        }
        fn start(&mut self, _: Arc<dyn AudioFrameConsumer>) -> Result<(), AudioCaptureError> {
            assert!(self.authorized);
            self.running = true;
            Ok(())
        }
        fn stop(&mut self) -> Result<(), AudioCaptureError> {
            self.running = false;
            Ok(())
        }
        fn is_running(&self) -> bool { self.running }
    }

    // Replay the bridge's decisions through the production worker's handler and
    // the real controller. Merely observing `suspended == false` missed the bug:
    // the controller still required a scene handle before starting its backend.
    let mut controller = AudioCaptureController::new(Arc::new(Consumer), Backend::default());
    for (handle, enabled) in engine.audio_capture_calls() {
        if scenes.contains(&handle) {
            if enabled && !controller.has_permission().unwrap() {
                assert!(controller.request_permission().unwrap());
            }
            controller.set_scene_capturing(handle, enabled).unwrap();
        }
    }
    for demand in engine.audio_capture_demands() {
        crate::engine::apply_audio_capture_demand(&mut controller, demand).unwrap();
        controller.retain_scenes(scenes).unwrap();
    }
    controller.is_capturing()
}

async fn audio_consumers(bridge: &WallpaperBridge) -> u32 {
    bridge
        .renderer_counters()
        .await
        .unwrap()
        .audio_active_consumers
}

#[tokio::test]
async fn capture_tap_follows_web_subscribers_with_no_scene_handle() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;

    assert_eq!(
        audio_consumers(&bridge).await,
        0,
        "a web wallpaper that has not registered an audio listener consumes nothing"
    );

    bridge
        .set_web_audio_subscribed("300".into(), 7, true)
        .await
        .unwrap();
    assert!(
        tap_open(&engine),
        "a subscribed web page is a consumer even though it has no scene"
    );
    assert_eq!(audio_consumers(&bridge).await, 1);

    bridge
        .set_web_audio_subscribed("300".into(), 7, false)
        .await
        .unwrap();
    assert!(
        !tap_open(&engine),
        "losing the last consumer must close the tap"
    );
    assert_eq!(audio_consumers(&bridge).await, 0);
}

#[tokio::test]
async fn web_capture_obeys_consent_pause_and_display_suspension() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;
    bridge.set_audio_response_enabled("300".into(), false).await.unwrap();
    bridge.set_web_audio_subscribed("300".into(), 7, true).await.unwrap();
    assert!(!tap_open(&engine), "a listener is not consent to capture");
    bridge.set_audio_response_enabled("300".into(), true).await.unwrap();
    // The page recomputes its demand when the host applies the new setting.
    bridge.set_web_audio_subscribed("300".into(), 7, true).await.unwrap();
    assert!(tap_open(&engine));
    bridge.set_display_presentation_suspended("7".into(), true).await.unwrap();
    assert!(!tap_open(&engine));
    bridge.set_display_presentation_suspended("7".into(), false).await.unwrap();
    assert!(tap_open(&engine));
    bridge.set_presentation_suspended(true).await.unwrap();
    assert!(!tap_open(&engine));
    bridge.set_presentation_suspended(false).await.unwrap();
    assert!(tap_open(&engine));
    bridge.set_audio_response_enabled("300".into(), false).await.unwrap();
    bridge.set_web_audio_subscribed("300".into(), 7, false).await.unwrap();
    assert!(!tap_open(&engine));
}

#[tokio::test]
async fn shutdown_releases_web_capture_without_waiting_for_a_page_to_unsubscribe() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;
    bridge.set_web_audio_subscribed("300".into(), 7, true).await.unwrap();
    assert!(tap_open(&engine));
    bridge.shutdown().await.unwrap();
    assert!(!tap_open(&engine));
}

#[tokio::test]
async fn a_web_listener_counts_beside_a_scene_that_reads_no_audio() {
    let engine = FakeEngineFacade::default();
    engine.scenes_start_without_audio();
    let bridge = web_bridge(&engine).await;
    // A scene wallpaper with audio response on, on a second display, whose
    // content reads no audio.
    let mut scene_display = display_snapshot(9);
    scene_display.handle = Some(SceneHandle::new(1));
    engine.set_snapshot(vec![display_snapshot(7), scene_display]);
    bridge.inject_scene_wallpaper_config_for_test("400", "Scene").await;
    bridge.set_display_config_enabled("400".into(), "9".into(), true).await.unwrap();
    bridge.apply_wallpaper_options("400".into(), true).await.unwrap();
    assert_eq!(audio_consumers(&bridge).await, 0, "neither the page nor the scene consumes yet");

    bridge.set_web_audio_subscribed("300".into(), 7, true).await.unwrap();
    assert!(tap_open(&engine), "the subscribed page alone keeps the tap open");
    assert_eq!(audio_consumers(&bridge).await, 1, "only the page counts");
}

#[tokio::test]
async fn muting_a_web_wallpaper_does_not_stop_its_audio_response() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;
    bridge
        .set_web_audio_subscribed("300".into(), 7, true)
        .await
        .unwrap();

    bridge.set_muted("300".into(), true).await.unwrap();

    assert_eq!(
        audio_consumers(&bridge).await,
        1,
        "mute silences output; it is not a switch for analysing what the system plays"
    );
    // Re-asserting the same subscription is what makes the tap state the
    // bridge computes after the mute observable.
    bridge
        .set_web_audio_subscribed("300".into(), 7, true)
        .await
        .unwrap();
    assert!(tap_open(&engine));
}

#[tokio::test]
async fn web_output_policy_mute_preserves_saved_mute_and_audio_response() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;
    bridge.play_all().await.unwrap();
    bridge.set_web_audio_subscribed("300".into(), 7, true).await.unwrap();
    bridge.set_volume("300".into(), 0.25).await.unwrap();

    bridge.set_audio_suppressed(true).await.unwrap();
    let wallpaper = bridge.web_wallpapers().await.unwrap().remove(0);
    assert!(wallpaper.muted);
    assert!(!wallpaper.paused);
    assert_eq!(wallpaper.volume, 0.25);
    assert_eq!(audio_consumers(&bridge).await, 1);

    bridge.set_audio_suppressed(false).await.unwrap();
    assert!(!bridge.web_wallpapers().await.unwrap()[0].muted);
    bridge.set_muted("300".into(), true).await.unwrap();
    bridge.set_audio_suppressed(true).await.unwrap();
    bridge.set_audio_suppressed(false).await.unwrap();
    assert!(bridge.web_wallpapers().await.unwrap()[0].muted);
    assert_eq!(audio_consumers(&bridge).await, 1);
}

#[tokio::test]
async fn turning_audio_response_off_removes_a_subscribed_web_page_as_a_consumer() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;
    bridge
        .set_web_audio_subscribed("300".into(), 7, true)
        .await
        .unwrap();
    assert_eq!(audio_consumers(&bridge).await, 1);

    bridge
        .set_audio_response_enabled("300".into(), false)
        .await
        .unwrap();

    assert_eq!(
        audio_consumers(&bridge).await,
        0,
        "a page still holding a listener consumes nothing once its wallpaper has audio response off"
    );
}

#[tokio::test]
async fn pausing_stops_a_web_page_from_consuming_audio() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;
    bridge
        .set_web_audio_subscribed("300".into(), 7, true)
        .await
        .unwrap();

    bridge.pause_all().await.unwrap();
    assert_eq!(audio_consumers(&bridge).await, 0);

    bridge.play_all().await.unwrap();
    assert_eq!(audio_consumers(&bridge).await, 1);
}

#[tokio::test]
async fn the_spectrum_a_page_reads_is_the_one_the_renderer_produced() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;

    assert!(
        bridge.web_audio_spectrum().unwrap().is_none(),
        "no analysis yet is not an all-zero spectrum"
    );

    let mut bins = [0.0_f32; 128];
    bins[3] = 0.75;
    bins[67] = 0.25;
    engine.set_audio_spectrum(Some(wallpaper_core::AudioSpectrum128 {
        generation: 42,
        stereo: true,
        bins,
    }));

    let spectrum = bridge.web_audio_spectrum().unwrap().unwrap();
    assert_eq!(spectrum.generation, 42);
    assert!(spectrum.stereo);
    assert_eq!(spectrum.bins.len(), 128);
    // Index 3 is the left channel, 67 the right: the halves must stay
    // independent rather than being averaged or mirrored on the way through.
    assert_eq!(spectrum.bins[3], 0.75);
    assert_eq!(spectrum.bins[67], 0.25);

    // A mono capture is the one case where the two halves are guaranteed
    // equal, so the fixture is built that way rather than as a state the
    // analyser cannot produce.
    let mut mono_bins = [0.0_f32; 128];
    mono_bins[3] = 0.5;
    mono_bins[67] = 0.5;
    engine.set_audio_spectrum(Some(wallpaper_core::AudioSpectrum128 {
        generation: 43,
        stereo: false,
        bins: mono_bins,
    }));
    assert!(
        !bridge.web_audio_spectrum().unwrap().unwrap().stereo,
        "a mono capture must never be reported as stereo"
    );
}

#[tokio::test]
async fn web_wallpapers_report_their_media_integration_consent() {
    let engine = FakeEngineFacade::default();
    let bridge = web_bridge(&engine).await;

    assert!(
        bridge.web_wallpapers().await.unwrap()[0].media_integration_enabled,
        "a wallpaper that never chose is reported as consenting: media integration is on by default"
    );
    assert!(
        bridge
            .wallpaper_options_snapshot("300".into())
            .await
            .unwrap()
            .media_integration_enabled
    );

    bridge
        .set_media_integration_enabled("300".into(), false)
        .await
        .unwrap();

    assert!(
        !bridge.web_wallpapers().await.unwrap()[0].media_integration_enabled,
        "an explicit opt-out is reported as such"
    );
    assert!(
        !bridge
            .wallpaper_options_snapshot("300".into())
            .await
            .unwrap()
            .media_integration_enabled
    );

    bridge
        .set_media_integration_enabled("300".into(), true)
        .await
        .unwrap();

    assert!(bridge.web_wallpapers().await.unwrap()[0].media_integration_enabled);
    assert!(
        bridge
            .wallpaper_options_snapshot("300".into())
            .await
            .unwrap()
            .media_integration_enabled
    );
}

#[tokio::test]
async fn a_late_media_event_never_overwrites_newer_state() {
    let bridge = WallpaperBridge::new_for_test();

    assert!(
        bridge.current_system_media_state().is_none(),
        "nothing known yet is not the same as known to be empty"
    );

    bridge
        .submit_system_media_event(
            r#"{"type":"mediaPropertiesChanged","generation":7,"title":"Second"}"#.into(),
        )
        .await
        .unwrap();
    // The artwork fetch for the previous track finishing after the track has
    // already changed is the case this ordering exists for.
    bridge
        .submit_system_media_event(
            r#"{"type":"mediaPropertiesChanged","generation":6,"title":"First"}"#.into(),
        )
        .await
        .unwrap();

    let state: serde_json::Value =
        serde_json::from_str(&bridge.current_system_media_state().unwrap()).unwrap();
    let events = state.as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["title"], "Second");
}

#[tokio::test]
async fn media_state_keeps_one_event_of_each_kind_verbatim() {
    let bridge = WallpaperBridge::new_for_test();

    for event in [
        r#"{"type":"mediaStatusChanged","enabled":true}"#,
        r#"{"type":"mediaPlaybackChanged","state":0}"#,
        r#"{"type":"mediaTimelineChanged","position":12.5,"duration":200.0}"#,
        r#"{"type":"mediaPlaybackChanged","state":1}"#,
    ] {
        bridge.submit_system_media_event(event.into()).await.unwrap();
    }

    let state: serde_json::Value =
        serde_json::from_str(&bridge.current_system_media_state().unwrap()).unwrap();
    let events = state.as_array().unwrap();
    assert_eq!(events.len(), 3, "one retained event per listener, not a log");
    let playback = events
        .iter()
        .find(|event| event["type"] == "mediaPlaybackChanged")
        .unwrap();
    assert_eq!(playback["state"], 1, "the newer playback state wins");
    let timeline = events
        .iter()
        .find(|event| event["type"] == "mediaTimelineChanged")
        .unwrap();
    // The payload contract belongs to the host; the bridge must hand back what
    // it was given rather than a reshaped version of it.
    assert_eq!(timeline["position"], 12.5);
    assert_eq!(timeline["duration"], 200.0);
}

#[tokio::test]
async fn an_unrecognised_media_event_is_refused_and_stores_nothing() {
    let bridge = WallpaperBridge::new_for_test();

    let error = bridge
        .submit_system_media_event(r#"{"type":"mediaLyricsChanged","lyrics":"…"}"#.into())
        .await
        .unwrap_err();

    assert_eq!(error.kind(), crate::BridgeErrorKind::InvalidInput);
    assert!(bridge.current_system_media_state().is_none());
}

#[tokio::test]
async fn scene_media_events_fan_out_only_to_opted_in_handles() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![DisplaySnapshotEntry {
        handle: Some(SceneHandle::new(11)),
        accepts_pointer_input: true,
        paused: false,
        window_active: true,
        assignment: Some(WallpaperAssignment::Direct(
            SceneTemplate::builder("/workshop/content/431960/100/project.json")
                .build()
                .unwrap(),
        )),
        ..display_snapshot(7)
    }]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .set_media_integration_enabled("100".into(), false)
        .await
        .unwrap();
    bridge
        .set_display_config_enabled("100".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();

    bridge
        .submit_system_media_event(r#"{"type":"mediaPlaybackChanged","state":0}"#.into())
        .await
        .unwrap();
    assert!(
        engine.media_event_calls().is_empty(),
        "a scene that never opted in must not receive media events"
    );

    bridge
        .set_media_integration_enabled("100".into(), true)
        .await
        .unwrap();
    assert_eq!(
        engine
            .media_integration_calls()
            .last()
            .map(|(_, enabled)| *enabled),
        Some(true)
    );

    bridge
        .submit_system_media_event(
            r#"{"type":"mediaPropertiesChanged","title":"Track","subTitle":"shown"}"#.into(),
        )
        .await
        .unwrap();
    let events = engine.media_event_calls();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].0, SceneHandle::new(11));
    assert!(
        events[0].1.contains("\"subTitle\":\"shown\""),
        "fan-out must keep the host JSON, not a narrower Rust model: {}",
        events[0].1
    );

    bridge
        .apply_system_media_artwork(2, 2, vec![0; 16])
        .await
        .unwrap();
    assert_eq!(
        engine.media_artwork_calls(),
        vec![(SceneHandle::new(11), 2, 2, 16)]
    );
    bridge.apply_system_media_artwork(0, 0, Vec::new()).await.unwrap();
    assert_eq!(engine.media_artwork_calls().last(), Some(&(SceneHandle::new(11), 0, 0, 0)));
    let calls = engine.media_artwork_calls().len();
    assert!(bridge.apply_system_media_artwork(0, 1, Vec::new()).await.is_err());
    assert!(bridge.apply_system_media_artwork(2, 2, vec![0; 4]).await.is_err());
    assert_eq!(engine.media_artwork_calls().len(), calls);
    bridge.apply_system_media_artwork(1, 1, vec![0, 200, 0, 255]).await.unwrap();
    assert_eq!(engine.media_artwork_calls().last(), Some(&(SceneHandle::new(11), 1, 1, 4)));
}

#[tokio::test]
async fn an_applied_scene_consents_to_media_by_default_and_events_reach_it() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![DisplaySnapshotEntry {
        handle: Some(SceneHandle::new(11)),
        accepts_pointer_input: true,
        paused: false,
        window_active: true,
        assignment: Some(WallpaperAssignment::Direct(
            SceneTemplate::builder("/workshop/content/431960/100/project.json")
                .build()
                .unwrap(),
        )),
        ..display_snapshot(7)
    }]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .set_display_config_enabled("100".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();

    assert_eq!(
        bridge.system_media_scene_handles().await.unwrap(),
        vec![11],
        "without any explicit choice the scene is a media consumer"
    );
    bridge
        .submit_system_media_event(r#"{"type":"mediaPlaybackChanged","state":0}"#.into())
        .await
        .unwrap();
    let events = engine.media_event_calls();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].0, SceneHandle::new(11));
}

#[tokio::test]
async fn scene_media_handles_follow_consent_so_nothing_reads_the_player_without_it() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![DisplaySnapshotEntry {
        handle: Some(SceneHandle::new(11)),
        accepts_pointer_input: true,
        paused: false,
        window_active: true,
        assignment: Some(WallpaperAssignment::Direct(
            SceneTemplate::builder("/workshop/content/431960/100/project.json")
                .build()
                .unwrap(),
        )),
        ..display_snapshot(7)
    }]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .set_media_integration_enabled("100".into(), false)
        .await
        .unwrap();
    bridge
        .set_display_config_enabled("100".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();

    assert!(
        bridge.system_media_scene_handles().await.unwrap().is_empty(),
        "an applied scene without consent must not make the host read the player"
    );

    bridge
        .set_media_integration_enabled("100".into(), true)
        .await
        .unwrap();
    assert_eq!(
        bridge.system_media_scene_handles().await.unwrap(),
        vec![11],
        "the consenting scene is named, so a host can tell a new instance from a known one"
    );

    bridge
        .set_media_integration_enabled("100".into(), false)
        .await
        .unwrap();
    assert!(
        bridge.system_media_scene_handles().await.unwrap().is_empty(),
        "turning the setting back off stops the source again"
    );
}

/// Consent says a wallpaper *may* receive media. It does not say anything is
/// there to receive it.
///
/// Every pause reason leaves the handle alive and the setting on, so asking
/// only "is there still a handle" kept the adapter process, its timeline
/// ticker and every fan-out running to update surfaces that had stopped
/// presenting. An incoming shortcut is judged on consent instead, which pause
/// does not revoke.
#[tokio::test]
async fn paused_and_suspended_scenes_stop_consuming_media_but_keep_their_consent() {
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![DisplaySnapshotEntry {
        handle: Some(SceneHandle::new(11)),
        accepts_pointer_input: true,
        paused: false,
        window_active: true,
        assignment: Some(WallpaperAssignment::Direct(
            SceneTemplate::builder("/workshop/content/431960/100/project.json")
                .build()
                .unwrap(),
        )),
        ..display_snapshot(7)
    }]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge
        .set_display_config_enabled("100".into(), "7".into(), true)
        .await
        .unwrap();
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    bridge
        .set_media_integration_enabled("100".into(), true)
        .await
        .unwrap();
    assert_eq!(bridge.system_media_scene_handles().await.unwrap(), vec![11]);

    bridge.pause_all().await.unwrap();
    assert!(
        bridge.system_media_scene_handles().await.unwrap().is_empty(),
        "a paused wallpaper kept the host reading the system player"
    );
    assert_eq!(
        bridge.system_media_consent_handles().await.unwrap(),
        vec![11],
        "pausing is not the user withdrawing permission"
    );

    let before = engine.media_event_calls().len();
    bridge
        .submit_system_media_event(r#"{"type":"mediaPlaybackChanged","state":1}"#.into())
        .await
        .unwrap();
    assert_eq!(
        engine.media_event_calls().len(),
        before,
        "a paused wallpaper was still being fed events"
    );

    bridge.play_all().await.unwrap();
    assert_eq!(
        bridge.system_media_scene_handles().await.unwrap(),
        vec![11],
        "resuming did not bring the consumer back"
    );

    // The same surface, stopped for a reason that is not global playback.
    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();
    assert!(
        bridge.system_media_scene_handles().await.unwrap().is_empty(),
        "an occluded display kept its scene consuming media"
    );
    bridge
        .set_display_presentation_suspended("7".into(), false)
        .await
        .unwrap();
    assert_eq!(bridge.system_media_scene_handles().await.unwrap(), vec![11]);

    bridge.set_presentation_suspended(true).await.unwrap();
    assert!(
        bridge.system_media_scene_handles().await.unwrap().is_empty(),
        "a global presentation suspend kept its scenes consuming media"
    );
}

/// One dark display must not silence the one the user is still looking at, and
/// must not keep being fed itself — through any entry point.
///
/// The fan-out and the older `GetSceneMediaWallpapers` / `UpdateSceneMedia`
/// pair answered different questions: the second pair looked only at global
/// playback, so a scene on an occluded display stayed eligible there after the
/// fan-out had already dropped it.
#[tokio::test]
async fn one_suspended_display_stops_only_its_own_scene_on_every_entry_point() {
    let scene = |id: u32| DisplaySnapshotEntry {
        handle: Some(SceneHandle::new(u64::from(id))),
        accepts_pointer_input: true,
        paused: false,
        window_active: true,
        assignment: Some(WallpaperAssignment::Direct(
            SceneTemplate::builder("/workshop/content/431960/100/project.json")
                .build()
                .unwrap(),
        )),
        ..display_snapshot(id)
    };
    let engine = FakeEngineFacade::default();
    engine.set_snapshot(vec![scene(7), scene(8)]);
    let bridge = BridgeBuilder::new(engine.clone())
        .with_state(crate::actor::state::BridgeActorState::default())
        .build()
        .unwrap();
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    for display in ["7", "8"] {
        bridge
            .set_display_config_enabled("100".into(), display.into(), true)
            .await
            .unwrap();
    }
    bridge.apply_wallpaper_options("100".into(), true).await.unwrap();
    bridge
        .set_media_integration_enabled("100".into(), true)
        .await
        .unwrap();

    let mut both = bridge.system_media_scene_handles().await.unwrap();
    both.sort_unstable();
    assert_eq!(both, vec![7, 8]);
    assert_eq!(
        bridge.scene_media_wallpaper_ids().await.unwrap(),
        vec!["100".to_string()],
        "both displays are presenting, so the wallpaper is listed"
    );

    bridge
        .set_display_presentation_suspended("7".into(), true)
        .await
        .unwrap();

    assert_eq!(
        bridge.system_media_scene_handles().await.unwrap(),
        vec![8],
        "the visible display kept consuming; only the dark one dropped out"
    );
    assert_eq!(
        bridge.scene_media_wallpaper_ids().await.unwrap(),
        vec!["100".to_string()],
        "a wallpaper still visible somewhere stays listed"
    );

    let events_before = engine.media_event_calls().len();
    let artwork_before = engine.media_artwork_calls().len();
    bridge
        .submit_system_media_event(r#"{"type":"mediaPlaybackChanged","state":1}"#.into())
        .await
        .unwrap();
    bridge
        .apply_system_media_artwork(2, 2, vec![0u8; 16])
        .await
        .unwrap();

    let events: Vec<SceneHandle> = engine.media_event_calls()[events_before..]
        .iter()
        .map(|(handle, _)| *handle)
        .collect();
    assert_eq!(
        events,
        vec![SceneHandle::new(8)],
        "the suspended display was still being fed events"
    );
    let artwork: Vec<SceneHandle> = engine.media_artwork_calls()[artwork_before..]
        .iter()
        .map(|call| call.0)
        .collect();
    assert_eq!(
        artwork,
        vec![SceneHandle::new(8)],
        "the suspended display was still being sent covers"
    );

    // Suspend the other one too: nothing is presenting, so nothing consumes.
    bridge
        .set_display_presentation_suspended("8".into(), true)
        .await
        .unwrap();
    assert!(bridge.system_media_scene_handles().await.unwrap().is_empty());
    assert!(
        bridge.scene_media_wallpaper_ids().await.unwrap().is_empty(),
        "the legacy list still named a wallpaper no display was showing"
    );
}

#[tokio::test]
async fn scene_optimization_defaults_on_and_survives_a_restart() {
    let temp = tempfile::tempdir().unwrap();
    let store = crate::config::ConfigStore::open(temp.path().to_path_buf());
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(store.clone())
        .build()
        .unwrap();

    assert!(
        bridge
            .settings_snapshot()
            .await
            .unwrap()
            .scene_optimization_enabled,
        "a rendering optimisation with no intended visual difference is on unless taken away"
    );

    let snapshot = bridge
        .set_scene_optimization_enabled(false)
        .await
        .unwrap()
        .settings;
    assert!(!snapshot.scene_optimization_enabled);
    assert_eq!(
        engine.scene_optimization_calls(),
        vec![false],
        "the renderer is told directly; a rebuild is not how a frame-building switch is applied"
    );
    assert!(
        engine.rendered_scenes().is_empty(),
        "changing it must not reopen or reparse anything"
    );

    drop(bridge);
    let restarted_engine = FakeEngineFacade::default();
    let restarted = BridgeBuilder::new(restarted_engine.clone())
        .with_config_store(store)
        .build()
        .unwrap();
    assert!(
        !restarted
            .settings_snapshot()
            .await
            .unwrap()
            .scene_optimization_enabled
    );
    restarted.bootstrap().await.unwrap();
    assert_eq!(
        restarted_engine.scene_optimization_calls().last().copied(),
        Some(false),
        "a process-wide renderer switch lives in C, so a saved opt-out has to be pushed back in"
    );
}

#[tokio::test]
async fn video_plane_sampling_defaults_off_and_survives_a_restart() {
    // The switch selects between two programs a running scene already holds, so
    // the properties that matter are: off unless asked for, pushed straight at
    // the renderer rather than through a rebuild, and pushed back in on the
    // next launch -- the value lives in C, not in the config the bridge reads.
    let temp = tempfile::tempdir().unwrap();
    let store = crate::config::ConfigStore::open(temp.path().to_path_buf());
    let engine = FakeEngineFacade::default();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(store.clone())
        .build()
        .unwrap();

    assert!(
        !bridge
            .settings_snapshot()
            .await
            .unwrap()
            .scene_video_plane_sampling_enabled,
        "a sampling path whose equivalence is bounded rather than total is opted into"
    );

    let snapshot = bridge
        .set_scene_video_plane_sampling_enabled(true)
        .await
        .unwrap()
        .settings;
    assert!(snapshot.scene_video_plane_sampling_enabled);
    assert_eq!(
        engine.scene_video_plane_sampling_calls(),
        vec![true],
        "the renderer is told directly; both programs were compiled with the graph"
    );
    assert!(
        engine.rendered_scenes().is_empty(),
        "changing it must not reopen, reparse or restart anything"
    );

    drop(bridge);
    let restarted_engine = FakeEngineFacade::default();
    let restarted = BridgeBuilder::new(restarted_engine.clone())
        .with_config_store(store)
        .build()
        .unwrap();
    assert!(
        restarted
            .settings_snapshot()
            .await
            .unwrap()
            .scene_video_plane_sampling_enabled
    );
    restarted.bootstrap().await.unwrap();
    assert_eq!(
        restarted_engine
            .scene_video_plane_sampling_calls()
            .last()
            .copied(),
        Some(true),
        "a process-wide renderer switch lives in C, so a saved opt-in has to be pushed back in"
    );
}

/// The tap is rebuilt when the default output device changes. The listener that
/// reports the change is `CoreAudio` glue and needs a device, so these replay
/// the worker's decisions through the production handlers and the real
/// controller with a scripted backend.
mod output_device_change {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    use wallpaper_core::media::audio::{
        AudioCaptureBackend, AudioCaptureController, AudioCaptureError, AudioFrameConsumer,
        InterleavedStereoF32, MonoPcmF32, RESTART_RETRY_DELAYS,
    };

    use super::{FakeEngineFacade, web_bridge};
    use crate::engine::{
        AudioCaptureDemand, AudioRestartState, OutputWatchGate, RestartAction,
        apply_audio_capture_demand, handle_audio_restart_retry, handle_output_device_change,
    };

    struct NullConsumer;

    impl AudioFrameConsumer for NullConsumer {
        fn submit_audio_frames(&self, _: InterleavedStereoF32<'_>) -> Result<(), AudioCaptureError> {
            Ok(())
        }
        fn submit_mono_audio_frames(&self, _: MonoPcmF32<'_>) -> Result<(), AudioCaptureError> {
            Ok(())
        }
    }

    /// A tap that always has permission and whose next `failing_starts` start
    /// attempts fail, as a start does while the new device is still settling.
    /// The count is shared so a test can change it while the controller owns
    /// the backend.
    #[derive(Default)]
    struct ScriptedBackend {
        running: bool,
        starts: usize,
        stops: usize,
        start_attempts: usize,
        failing_starts: Arc<AtomicUsize>,
    }

    impl AudioCaptureBackend for ScriptedBackend {
        fn has_permission(&self) -> Result<bool, AudioCaptureError> {
            Ok(true)
        }
        fn request_permission(&mut self) -> Result<bool, AudioCaptureError> {
            Ok(true)
        }
        fn start(&mut self, _: Arc<dyn AudioFrameConsumer>) -> Result<(), AudioCaptureError> {
            self.start_attempts += 1;
            let failing = self.failing_starts.load(Ordering::SeqCst);
            if failing > 0 {
                self.failing_starts.store(failing - 1, Ordering::SeqCst);
                return Err(AudioCaptureError::Platform(
                    "AudioDeviceStart failed (OSStatus=-10851)".into(),
                ));
            }
            self.running = true;
            self.starts += 1;
            Ok(())
        }
        fn stop(&mut self) -> Result<(), AudioCaptureError> {
            if std::mem::take(&mut self.running) {
                self.stops += 1;
            }
            Ok(())
        }
        fn is_running(&self) -> bool {
            self.running
        }
    }

    type Controller = AudioCaptureController<ScriptedBackend>;

    fn controller() -> (Controller, Arc<AtomicUsize>) {
        let backend = ScriptedBackend::default();
        let failing_starts = Arc::clone(&backend.failing_starts);
        (AudioCaptureController::new(Arc::new(NullConsumer), backend), failing_starts)
    }

    fn web_demand(suspended: bool) -> AudioCaptureDemand {
        AudioCaptureDemand { suspended, external_consumers: true }
    }

    /// A web-only session: no scene handle, only a page that asked for audio.
    fn web_only_controller() -> (Controller, Arc<AtomicUsize>) {
        let (mut controller, failing_starts) = controller();
        apply_audio_capture_demand(&mut controller, web_demand(false)).unwrap();
        assert!(controller.is_capturing());
        (controller, failing_starts)
    }

    /// Follows the retry chain the worker would schedule until it stops,
    /// returning the delays it asked for.
    fn run_retries(
        controller: &mut Controller,
        state: &AudioRestartState,
        mut action: RestartAction,
    ) -> (Vec<std::time::Duration>, RestartAction) {
        let mut delays = Vec::new();
        while let RestartAction::RetryIn { delay, generation, attempt } = action {
            delays.push(delay);
            action = handle_audio_restart_retry(controller, state, generation, attempt);
        }
        (delays, action)
    }

    #[tokio::test]
    async fn output_device_change_restarts_capture_for_a_web_only_session() {
        let engine = FakeEngineFacade::default();
        let bridge = web_bridge(&engine).await;
        bridge.set_web_audio_subscribed("300".into(), 7, true).await.unwrap();
        // What the audio worker was asked to do for that page, replayed.
        let (mut controller, _) = controller();
        for demand in engine.audio_capture_demands() {
            apply_audio_capture_demand(&mut controller, demand).unwrap();
            controller.retain_scenes(&[]).unwrap();
        }
        assert!(controller.is_capturing(), "the page alone owns a running tap");
        assert_eq!(controller.backend().starts, 1);

        let mut state = AudioRestartState::default();
        let action = handle_output_device_change(&mut controller, &mut state);

        assert_eq!(action, RestartAction::Done);
        assert!(controller.is_capturing(), "capture follows the new device");
        assert_eq!(
            (controller.backend().stops, controller.backend().starts),
            (1, 2),
            "the tap bound to the old device is released and a new one started"
        );
    }

    #[test]
    fn a_device_change_without_running_capture_does_nothing() {
        let mut state = AudioRestartState::default();

        let (mut idle, _) = controller();
        assert_eq!(handle_output_device_change(&mut idle, &mut state), RestartAction::Done);
        assert_eq!((idle.backend().start_attempts, idle.backend().stops), (0, 0));

        let (mut paused, _) = web_only_controller();
        apply_audio_capture_demand(&mut paused, web_demand(true)).unwrap();
        assert!(!paused.is_capturing());
        let (attempts, stops) = (paused.backend().start_attempts, paused.backend().stops);
        assert_eq!(handle_output_device_change(&mut paused, &mut state), RestartAction::Done);
        assert_eq!(
            (paused.backend().start_attempts, paused.backend().stops),
            (attempts, stops),
            "a paused display must not wake the tap"
        );
        apply_audio_capture_demand(&mut paused, web_demand(false)).unwrap();
        assert!(paused.is_capturing(), "resuming starts on whatever device is current");
    }

    #[test]
    fn retries_use_the_three_delays_then_give_up() {
        let (mut controller, failing_starts) = web_only_controller();
        failing_starts.store(usize::MAX, Ordering::SeqCst);
        let mut state = AudioRestartState::default();

        let first = handle_output_device_change(&mut controller, &mut state);
        let (delays, last) = run_retries(&mut controller, &state, first);

        assert_eq!(delays, RESTART_RETRY_DELAYS, "each retry waits its own delay, in order");
        assert_eq!(last, RestartAction::GaveUp);
        assert_eq!(
            controller.backend().start_attempts,
            1 + 1 + RESTART_RETRY_DELAYS.len(),
            "the first tap, the immediate rebuild and then one try per delay, no more"
        );
        assert!(!controller.is_capturing());

        // Giving up leaves the heal to the next scene or demand change.
        failing_starts.store(0, Ordering::SeqCst);
        apply_audio_capture_demand(&mut controller, web_demand(false)).unwrap();
        assert!(controller.is_capturing());
    }

    #[test]
    fn a_retry_that_succeeds_ends_the_chain() {
        let (mut controller, failing_starts) = web_only_controller();
        failing_starts.store(2, Ordering::SeqCst);
        let mut state = AudioRestartState::default();

        let first = handle_output_device_change(&mut controller, &mut state);
        let (delays, last) = run_retries(&mut controller, &state, first);

        assert_eq!(delays, RESTART_RETRY_DELAYS[..2], "it stops asking once the tap is back");
        assert_eq!(last, RestartAction::Done);
        assert!(controller.is_capturing());
        assert_eq!(controller.backend().stops, 1, "the retry started a tap; it did not rebuild one");
    }

    #[test]
    fn a_newer_device_change_invalidates_a_pending_retry() {
        let (mut controller, failing_starts) = web_only_controller();
        failing_starts.store(2, Ordering::SeqCst);
        let mut state = AudioRestartState::default();

        let RestartAction::RetryIn { generation: stale, attempt, .. } =
            handle_output_device_change(&mut controller, &mut state)
        else {
            panic!("the first rebuild fails and asks for a retry");
        };
        // A second change arrives before that retry is due, and fails too.
        let RestartAction::RetryIn { generation: current, .. } =
            handle_output_device_change(&mut controller, &mut state)
        else {
            panic!("the second rebuild also fails and asks for a retry");
        };
        assert_ne!(stale, current);
        assert!(!controller.is_capturing());
        let attempts = controller.backend().start_attempts;

        assert_eq!(
            handle_audio_restart_retry(&mut controller, &state, stale, attempt),
            RestartAction::Done,
            "the older change's retry is superseded"
        );
        assert_eq!(controller.backend().start_attempts, attempts, "it started nothing");

        assert_eq!(
            handle_audio_restart_retry(&mut controller, &state, current, 1),
            RestartAction::Done,
            "the newer change's retry still runs"
        );
        assert!(controller.is_capturing());
    }

    #[test]
    fn a_retry_never_tears_down_a_tap_that_started_in_the_meantime() {
        let (mut controller, failing_starts) = web_only_controller();
        failing_starts.store(1, Ordering::SeqCst);
        let mut state = AudioRestartState::default();
        let RestartAction::RetryIn { generation, attempt, .. } =
            handle_output_device_change(&mut controller, &mut state)
        else {
            panic!("the rebuild fails and asks for a retry");
        };

        // A page asks for audio again before the retry is due.
        apply_audio_capture_demand(&mut controller, web_demand(false)).unwrap();
        assert!(controller.is_capturing());
        let (starts, stops) = (controller.backend().starts, controller.backend().stops);

        assert_eq!(
            handle_audio_restart_retry(&mut controller, &state, generation, attempt),
            RestartAction::Done
        );
        assert_eq!(
            (controller.backend().starts, controller.backend().stops),
            (starts, stops),
            "a healthy tap is left alone"
        );
    }
    /// A stand-in for the real watcher that counts how many are alive.
    struct LiveWatcher(Arc<AtomicUsize>);

    impl Drop for LiveWatcher {
        fn drop(&mut self) {
            self.0.fetch_sub(1, Ordering::SeqCst);
        }
    }

    /// What the worker does after each command: key the watcher off the
    /// controller. `fail` makes the start return nothing, as a failed one does.
    fn sync_watch(
        gate: &mut OutputWatchGate<LiveWatcher>,
        controller: &Controller,
        alive: &Arc<AtomicUsize>,
        starts: &Arc<AtomicUsize>,
        fail: bool,
    ) {
        gate.sync(controller.wants_capture(), || {
            starts.fetch_add(1, Ordering::SeqCst);
            if fail {
                return None;
            }
            alive.fetch_add(1, Ordering::SeqCst);
            Some(LiveWatcher(Arc::clone(alive)))
        });
    }

    #[test]
    fn the_output_watcher_exists_only_while_capture_is_wanted() {
        let (mut controller, _) = controller();
        let mut gate = OutputWatchGate::default();
        let (alive, starts) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));

        // A process whose wallpapers never read audio never holds a watcher,
        // however many commands the worker sees.
        for _ in 0..3 {
            controller.retain_scenes(&[]).unwrap();
            sync_watch(&mut gate, &controller, &alive, &starts, false);
        }
        assert_eq!((starts.load(Ordering::SeqCst), alive.load(Ordering::SeqCst)), (0, 0));
        assert!(!gate.is_watching());

        apply_audio_capture_demand(&mut controller, web_demand(false)).unwrap();
        sync_watch(&mut gate, &controller, &alive, &starts, false);
        sync_watch(&mut gate, &controller, &alive, &starts, false);
        assert!(gate.is_watching(), "a tap that may need rebuilding has a watcher");
        assert_eq!(starts.load(Ordering::SeqCst), 1, "one watcher, not one per command");

        // Suspended: nothing runs, so a device change has nothing to rebuild.
        apply_audio_capture_demand(&mut controller, web_demand(true)).unwrap();
        sync_watch(&mut gate, &controller, &alive, &starts, false);
        assert!(!gate.is_watching());
        assert_eq!(alive.load(Ordering::SeqCst), 0, "the watcher is released, not parked");

        apply_audio_capture_demand(&mut controller, web_demand(false)).unwrap();
        sync_watch(&mut gate, &controller, &alive, &starts, false);
        assert!(gate.is_watching());
        assert_eq!(starts.load(Ordering::SeqCst), 2);
        assert_eq!(alive.load(Ordering::SeqCst), 1);

        // The last consumer leaving releases it too.
        apply_audio_capture_demand(
            &mut controller,
            AudioCaptureDemand { suspended: false, external_consumers: false },
        )
        .unwrap();
        sync_watch(&mut gate, &controller, &alive, &starts, false);
        assert!(!gate.is_watching());
        assert_eq!(alive.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn a_watcher_that_could_not_start_is_tried_again_only_when_capture_is_wanted_anew() {
        let (mut controller, _) = controller();
        let mut gate = OutputWatchGate::default();
        let (alive, starts) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));

        apply_audio_capture_demand(&mut controller, web_demand(false)).unwrap();
        for _ in 0..5 {
            sync_watch(&mut gate, &controller, &alive, &starts, true);
        }
        assert_eq!(
            starts.load(Ordering::SeqCst),
            1,
            "a failed start is logged once, not on every command"
        );
        assert!(!gate.is_watching());

        apply_audio_capture_demand(&mut controller, web_demand(true)).unwrap();
        sync_watch(&mut gate, &controller, &alive, &starts, true);
        apply_audio_capture_demand(&mut controller, web_demand(false)).unwrap();
        sync_watch(&mut gate, &controller, &alive, &starts, false);
        assert_eq!(starts.load(Ordering::SeqCst), 2);
        assert!(gate.is_watching(), "the next time capture is wanted it is tried again");
    }
}
