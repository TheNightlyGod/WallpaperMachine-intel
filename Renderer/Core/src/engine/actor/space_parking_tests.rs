//! A display may keep the scenes it leaves loaded and paused, so a wallpaper
//! that comes back runs on from where it stopped instead of loading again.
use super::{
    EngineActor,
    main_display_tests::{RuntimeFacade, builtin, engine_for, external, running_on, scene},
};
use crate::{
    DisplayDesc,
    display::state::DisplayStateModel,
    engine::runtime::RuntimeRefreshMode,
    project::SceneHandle,
};

fn tokio() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("test runtime")
}

fn path(wallpaper: &str) -> String {
    format!("/library/{wallpaper}/scene.json")
}

fn two_displays() -> EngineActor {
    let mut model = DisplayStateModel::from_config(crate::WallpaperEngineConfig::default())
        .expect("default model");
    model
        .refresh_connected(builtin(), vec![builtin(), external()])
        .expect("first report");
    engine_for(model)
}

/// Shows `wallpaper` on the built-in display and marks the scene as having
/// presented, as a real renderer would after its first frame.
fn show(actor: &mut EngineActor, facade: &RuntimeFacade, display: &DisplayDesc, wallpaper: &str) {
    facade
        .update(actor, |model| model.apply_reconcile(&[scene(display, wallpaper)]))
        .expect("reconcile");
    let record = actor
        .state
        .display_records
        .iter_mut()
        .find(|record| record.runtime.as_ref().is_some_and(|live| live.display_id() == display.display_id))
        .expect("a live scene");
    record.runtime.as_mut().expect("checked").presented_for_test = true;
}

/// Marks every live scene as having presented.
fn mark_presented(actor: &mut EngineActor) {
    for record in &mut actor.state.display_records {
        if let Some(live) = record.runtime.as_mut() {
            live.presented_for_test = true;
        }
    }
}

/// The wallpapers the display keeps parked, with their handles and pauses.
fn parked_on(actor: &EngineActor, display: &DisplayDesc) -> Vec<(String, SceneHandle, bool)> {
    actor
        .state
        .display_records
        .iter()
        .flat_map(|record| &record.parked)
        .filter(|parked| parked.runtime.display_id() == display.display_id)
        .map(|parked| (parked.runtime.desc.scene_path.clone(), parked.handle, parked.runtime.paused()))
        .collect()
}

#[test]
fn a_wallpaper_the_display_left_runs_again_without_a_load() {
    let tokio = tokio();
    let _context = tokio.enter();
    let mut actor = two_displays();
    let facade = RuntimeFacade::default();
    actor.set_parked_scenes(1, vec![path("aurora"), path("basalt")]).expect("parking list");

    show(&mut actor, &facade, &builtin(), "aurora");
    let (_, aurora, _) = running_on(&actor, &builtin());
    facade.forget();

    show(&mut actor, &facade, &builtin(), "basalt");
    let (_, basalt, running) = running_on(&actor, &builtin());
    assert_eq!(running, path("basalt"));
    assert_ne!(basalt, aurora, "the new wallpaper is a scene of its own");
    assert!(
        matches!(facade.jobs.borrow().as_slice(), [(_, RuntimeRefreshMode::OpenRuntime)]),
        "the new wallpaper opens in a new window instead of replacing the old one: {:?}",
        facade.jobs.borrow()
    );
    assert_eq!(parked_on(&actor, &builtin()), vec![(path("aurora"), aurora, true)]);
    facade.forget();

    facade
        .update(&mut actor, |model| model.apply_reconcile(&[scene(&builtin(), "aurora")]))
        .expect("back to the first wallpaper");
    assert!(facade.jobs.borrow().is_empty(), "nothing loads: {:?}", facade.jobs.borrow());
    let (key, handle, running) = running_on(&actor, &builtin());
    assert_eq!((handle, running.as_str()), (aurora, path("aurora").as_str()));
    assert_eq!(actor.handle_for_key(&key).expect("lookup"), Some(aurora));
    let live = actor.state.display_records.iter().find_map(|record| record.runtime.as_ref()
        .filter(|live| live.display_id() == 1)).expect("live");
    assert!(!live.paused(), "it runs with the descriptor's pause");
    assert_eq!(parked_on(&actor, &builtin()), vec![(path("basalt"), basalt, true)]);

    let scenes = actor.state.snapshot().scenes;
    let listed: Vec<_> = scenes.iter().map(|entry| (entry.handle, entry.parked)).collect();
    assert_eq!(listed, vec![(aurora, false), (basalt, true)]);
}

#[test]
fn a_kept_scene_takes_the_sound_and_frame_rate_it_missed_without_a_load() {
    let tokio = tokio();
    let _context = tokio.enter();
    let mut actor = two_displays();
    let facade = RuntimeFacade::default();
    actor.set_parked_scenes(1, vec![path("aurora"), path("basalt")]).expect("parking list");
    show(&mut actor, &facade, &builtin(), "aurora");
    let (_, aurora, _) = running_on(&actor, &builtin());
    show(&mut actor, &facade, &builtin(), "basalt");
    facade.forget();

    // Another app started playing sound and the battery capped the frame rate meanwhile.
    let mut back = scene(&builtin(), "aurora");
    back.audio_muted = true;
    back.fps = 24;
    facade
        .update(&mut actor, |model| model.apply_reconcile(&[back]))
        .expect("back to the first wallpaper");
    assert!(facade.jobs.borrow().is_empty(), "nothing loads: {:?}", facade.jobs.borrow());
    assert_eq!(running_on(&actor, &builtin()).1, aurora);
    let live = actor.state.display_records.iter().find_map(|record| record.runtime.as_ref()
        .filter(|live| live.display_id() == 1)).expect("live");
    assert!(live.desc.audio_muted);
    assert_eq!(live.desc.fps, 24);
}

#[test]
fn a_display_that_keeps_nothing_replaces_its_scene_in_place_as_before() {
    let tokio = tokio();
    let _context = tokio.enter();
    let mut actor = two_displays();
    let facade = RuntimeFacade::default();
    show(&mut actor, &facade, &builtin(), "aurora");
    let (_, aurora, _) = running_on(&actor, &builtin());
    facade.forget();

    show(&mut actor, &facade, &builtin(), "basalt");
    assert!(matches!(facade.jobs.borrow().as_slice(), [(_, RuntimeRefreshMode::RebuildExistingRuntime)]));
    assert_eq!(running_on(&actor, &builtin()).1, aurora, "the handle stays with the slot");
    assert!(parked_on(&actor, &builtin()).is_empty());
}

#[test]
fn a_scene_that_has_not_drawn_is_replaced_rather_than_kept() {
    let tokio = tokio();
    let _context = tokio.enter();
    let mut actor = two_displays();
    let facade = RuntimeFacade::default();
    actor.set_parked_scenes(1, vec![path("aurora"), path("basalt")]).expect("parking list");
    facade
        .update(&mut actor, |model| model.apply_reconcile(&[scene(&builtin(), "aurora")]))
        .expect("reconcile");
    facade.forget();

    show(&mut actor, &facade, &builtin(), "basalt");
    assert!(matches!(facade.jobs.borrow().as_slice(), [(_, RuntimeRefreshMode::RebuildExistingRuntime)]));
    assert!(parked_on(&actor, &builtin()).is_empty(), "a black window is not worth keeping");
}

#[test]
fn a_returning_wallpaper_closes_a_live_scene_the_display_may_not_keep() {
    let tokio = tokio();
    let _context = tokio.enter();
    let mut actor = two_displays();
    let facade = RuntimeFacade::default();
    actor.set_parked_scenes(1, vec![path("aurora")]).expect("parking list");
    show(&mut actor, &facade, &builtin(), "aurora");
    let (_, aurora, _) = running_on(&actor, &builtin());
    show(&mut actor, &facade, &builtin(), "basalt");
    facade.forget();

    facade
        .update(&mut actor, |model| model.apply_reconcile(&[scene(&builtin(), "aurora")]))
        .expect("back to the kept wallpaper");
    assert!(facade.jobs.borrow().is_empty(), "nothing loads: {:?}", facade.jobs.borrow());
    assert_eq!(running_on(&actor, &builtin()).1, aurora);
    assert!(parked_on(&actor, &builtin()).is_empty(), "basalt was not to be kept");
}

#[test]
fn parked_scenes_close_when_the_list_drops_them() {
    let tokio = tokio();
    let _context = tokio.enter();
    let mut actor = two_displays();
    let facade = RuntimeFacade::default();
    actor.set_parked_scenes(1, vec![path("aurora"), path("basalt")]).expect("parking list");
    show(&mut actor, &facade, &builtin(), "aurora");
    show(&mut actor, &facade, &builtin(), "basalt");
    assert_eq!(parked_on(&actor, &builtin()).len(), 1);

    actor.set_parked_scenes(1, vec![path("basalt")]).expect("shorter list");
    assert!(parked_on(&actor, &builtin()).is_empty());
    assert_eq!(running_on(&actor, &builtin()).2, path("basalt"), "the live scene stays");
    assert!(actor.state.parking.contains_key(&1));

    actor.set_parked_scenes(1, Vec::new()).expect("empty list");
    assert!(!actor.state.parking.contains_key(&1), "an empty list keeps nothing");
}

#[test]
fn parked_scenes_close_with_their_display_or_a_new_size() {
    let tokio = tokio();
    let _context = tokio.enter();
    let mut actor = two_displays();
    let facade = RuntimeFacade::default();
    actor.set_parked_scenes(5, vec![path("aurora"), path("basalt")]).expect("parking list");
    let park_aurora = |actor: &mut EngineActor, external: &DisplayDesc| {
        mark_presented(actor);
        facade
            .update(actor, |model| {
                model.apply_reconcile(&[scene(&builtin(), "cobalt"), scene(external, "aurora")])
            })
            .expect("reconcile");
        mark_presented(actor);
        facade
            .update(actor, |model| {
                model.apply_reconcile(&[scene(&builtin(), "cobalt"), scene(external, "basalt")])
            })
            .expect("external moves on");
        assert_eq!(parked_on(actor, external).len(), 1);
        facade.forget();
    };
    park_aurora(&mut actor, &external());

    // A new resolution: the parked window would be the wrong size.
    let resized = DisplayDesc::with_identity(5, external().identity.clone(), 1512, 0, 2560, 1440, 2.0);
    facade
        .update(&mut actor, |model| {
            model.refresh_connected_keeping(builtin(), vec![builtin(), resized.clone()], &[]).map(|_| ())
        })
        .expect("display resized");
    assert!(parked_on(&actor, &resized).is_empty(), "the parked scene closed");
    assert_eq!(facade.closes.get(), 1, "only the parked scene closed");
    facade.forget();

    // Parked again, then the display goes away with everything it kept.
    park_aurora(&mut actor, &resized);
    facade
        .update(&mut actor, |model| {
            model.refresh_connected_keeping(builtin(), vec![builtin()], &[]).map(|_| ())
        })
        .expect("display unplugged");
    assert!(
        actor.state.display_records.iter().all(|record| record.parked.is_empty()),
        "nothing stays parked for a display that is gone"
    );
    assert_eq!(facade.closes.get(), 2, "the live and the parked scene closed");
}

#[test]
fn a_global_resume_leaves_parked_scenes_paused() {
    let tokio = tokio();
    let _context = tokio.enter();
    let mut actor = two_displays();
    let facade = RuntimeFacade::default();
    actor.set_parked_scenes(1, vec![path("aurora"), path("basalt")]).expect("parking list");
    show(&mut actor, &facade, &builtin(), "aurora");
    show(&mut actor, &facade, &builtin(), "basalt");

    actor.set_all_paused(true, &[]).expect("pause");
    actor.set_all_paused(false, &[]).expect("resume");
    assert_eq!(parked_on(&actor, &builtin()).iter().map(|(_, _, paused)| *paused).collect::<Vec<_>>(), vec![true]);
    let live = actor.state.snapshot().displays.into_iter().find(|entry| entry.desc.display_id == 1).expect("listed");
    assert!(!live.paused, "the live scene resumed");
}

#[test]
fn closing_everything_closes_parked_scenes_too() {
    let tokio = tokio();
    let _context = tokio.enter();
    let mut actor = two_displays();
    let facade = RuntimeFacade::default();
    actor.set_parked_scenes(1, vec![path("aurora"), path("basalt")]).expect("parking list");
    show(&mut actor, &facade, &builtin(), "aurora");
    show(&mut actor, &facade, &builtin(), "basalt");

    actor.close_all_scenes().expect("close all");
    assert!(actor.state.display_records.iter().all(|record| record.parked.is_empty() && record.runtime.is_none()));
    assert!(actor.state.snapshot().scenes.is_empty());
}
