use super::EngineActor;
use crate::{
    EngineError,
    engine::{
        runtime::{SceneRuntime, SceneRuntimeState},
        state::ParkedRuntime,
    },
    project::{SceneDesc, SceneHandle},
};

impl EngineActor {
    /// Opens an unvisited desktop's scene without changing the live assignment.
    pub fn preload_scene(&mut self, desc: SceneDesc, render_scale: f64) -> Result<(), EngineError> {
        if !render_scale.is_finite() || !(0.25..=1.0).contains(&render_scale) {
            return Err(EngineError::InvalidInput(
                "invalid preload render scale".into(),
            ));
        }
        let backend = self.backend;
        let actor = self.weak_self.clone();
        let downstream = self.first_frame_callback.clone();
        self.preload_scene_with(desc, move |handle, desc| {
            let (ready, received) = tokio::sync::oneshot::channel();
            let ready = std::sync::Mutex::new(Some(ready));
            let callback = std::sync::Arc::new(move |handle| {
                if let Some(ready) = ready.lock().unwrap().take() {
                    let _ = ready.send(());
                }
                downstream(handle);
            });
            let mut runtime = SceneRuntime::open_preloaded(
                backend,
                callback,
                handle,
                desc,
                SceneRuntimeState::try_from(desc)?,
                actor.clone(),
            )?;
            runtime.set_render_scale(render_scale)?;
            tokio::spawn(async move {
                let expired = tokio::time::timeout(std::time::Duration::from_secs(90), received)
                    .await
                    .is_err();
                if let Some(actor) = actor.upgrade() {
                    let _ = actor
                        .tell(super::super::messages::FinishScenePreload { handle, expired })
                        .send()
                        .await;
                }
            });
            Ok(runtime)
        })
    }

    fn preload_scene_with(
        &mut self,
        mut desc: SceneDesc,
        open: impl FnOnce(SceneHandle, &SceneDesc) -> Result<SceneRuntime, EngineError>,
    ) -> Result<(), EngineError> {
        if !self
            .state
            .may_park(desc.display.display_id, &desc.scene_path)
        {
            return Ok(());
        }
        let Some(index) = self
            .state
            .display_records
            .iter()
            .position(|record| record.model.live_display.as_ref() == Some(&desc.display))
        else {
            return Ok(());
        };
        let record = &self.state.display_records[index];
        if record
            .runtime
            .iter()
            .chain(record.parked.iter().map(|parked| &parked.runtime))
            .any(|runtime| runtime.desc.scene_path == desc.scene_path)
        {
            return Ok(());
        }
        desc.validate()?;
        // The first frame needs the clock. Only this instance is muted; the saved config is untouched.
        desc.paused = false;
        desc.audio_muted = true;
        let handle = SceneHandle::new(self.state.next_handle);
        self.state.next_handle = self.state.next_handle.saturating_add(1);
        let runtime = open(handle, &desc)?;
        self.state.display_records[index]
            .parked
            .push(ParkedRuntime { handle, runtime });
        Ok(())
    }

    pub fn finish_scene_preload(
        &mut self,
        handle: SceneHandle,
        expired: bool,
    ) -> Result<(), EngineError> {
        for record in &mut self.state.display_records {
            let Some(index) = record
                .parked
                .iter()
                .position(|parked| parked.handle == handle)
            else {
                continue;
            };
            let runtime = &mut record.parked[index].runtime;
            if !expired && runtime.has_presented() && runtime.set_paused(true).is_ok() {
                log::info!(
                    "[wallpaper-core display] preloaded {} paused on display {}",
                    runtime.desc.scene_path,
                    runtime.display_id()
                );
                return Ok(());
            }
            let mut parked = record.parked.remove(index);
            log::warn!(
                "[wallpaper-core display] releasing unfinished desktop preload {}",
                parked.runtime.desc.scene_path
            );
            return parked.runtime.close();
        }
        // A switch may already have promoted it, or memory pressure may have released it.
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kameo::actor::Spawn;
    use std::sync::{Arc, Mutex};
    use crate::engine::actor::main_display_tests::{RuntimeFacade, builtin, running_on, scene};
    use crate::engine::actor::space_parking_tests::{parked_on, path, show, two_displays};
    use crate::engine::messages::NativeAudioRequirementChanged;

    /// Delivers the real notification messages and returns the actor after draining them.
    async fn report_audio_requirements(
        mut actor: EngineActor,
        reports: Vec<NativeAudioRequirementChanged>,
    ) -> EngineActor {
        let prepared = EngineActor::prepare();
        let actor_ref = prepared.actor_ref().clone();
        actor.weak_self = actor_ref.downgrade();
        let join = prepared.spawn(actor);
        for report in reports {
            actor_ref.ask(report).await.unwrap();
        }
        actor_ref.stop_gracefully().await.unwrap();
        actor_ref.wait_for_shutdown().await;
        join.await.unwrap().unwrap().0
    }

    #[tokio::test(flavor = "current_thread")]
    async fn preloaded_audio_demand_is_retained_until_promotion_without_exposing_parked_commands() {
        let mut actor = two_displays();
        let facade = RuntimeFacade::default();
        actor.set_parked_scenes(1, vec![path("aurora"), path("basalt")]).unwrap();
        show(&mut actor, &facade, &builtin(), "aurora");
        let weak = actor.weak_self.clone();
        let mut token = None;
        actor.preload_scene_with(scene(&builtin(), "basalt"), |handle, desc| {
            let mut runtime = SceneRuntime::windowless_for_test(
                handle, desc, &SceneRuntimeState::try_from(desc)?, weak,
            )?;
            runtime.presented_for_test = true;
            token = Some(runtime.enable_audio_reports_for_test());
            Ok(runtime)
        }).unwrap();
        let handle = parked_on(&actor, &builtin())[0].1;
        let token = token.unwrap();
        actor.finish_scene_preload(handle, false).unwrap();
        assert!(actor.state.scene_mut(handle).is_err(), "a preload is not a command target");

        let snapshots = actor.snapshots.clone();
        let events = Arc::new(Mutex::new(Vec::new()));
        let observed = events.clone();
        snapshots.audio_requirement().set_callback(Some(Arc::new(move |handle, required| {
            observed.lock().unwrap().push((handle, required));
        })));
        actor = report_audio_requirements(actor, vec![
            NativeAudioRequirementChanged { handle, renderer_instance: token.clone(), requires_audio: true },
            NativeAudioRequirementChanged { handle, renderer_instance: Arc::new(()), requires_audio: false },
            NativeAudioRequirementChanged { handle: SceneHandle::new(u64::MAX), renderer_instance: token.clone(), requires_audio: true },
        ]).await;
        assert!(actor.state.display_records.iter().flat_map(|record| &record.parked)
            .find(|parked| parked.handle == handle).unwrap().runtime.requires_audio(),
            "the initial capability report must survive while parked");
        assert!(actor.state.scene_mut(handle).is_err());
        assert!(!snapshots.audio_requirement().requires_audio(handle));
        assert!(events.lock().unwrap().is_empty(), "parked demand must not start capture");

        facade.forget();
        facade.update(&mut actor, |model| model.apply_reconcile(&[scene(&builtin(), "basalt")])).unwrap();
        actor.publish_snapshot();
        assert!(facade.jobs.borrow().is_empty(), "promotion must reuse the prepared runtime");
        assert_eq!(running_on(&actor, &builtin()).1, handle);
        assert!(snapshots.audio_requirement().requires_audio(handle));
        assert_eq!(*events.lock().unwrap(), vec![(handle, true)]);

        actor = report_audio_requirements(actor, vec![
            NativeAudioRequirementChanged { handle, renderer_instance: token, requires_audio: false },
            NativeAudioRequirementChanged { handle, renderer_instance: Arc::new(()), requires_audio: true },
        ]).await;
        assert!(!actor.state.scene_mut(handle).unwrap().requires_audio());
        assert_eq!(*events.lock().unwrap(), vec![(handle, true), (handle, false)]);
    }

    #[test]
    fn unvisited_wallpaper_is_prepared_without_changing_the_live_scene_and_resumes_without_loading()
    {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let _context = runtime.enter();
        let mut actor = two_displays();
        let facade = RuntimeFacade::default();
        actor
            .set_parked_scenes(1, vec![path("aurora"), path("basalt")])
            .unwrap();
        show(&mut actor, &facade, &builtin(), "aurora");
        let before = running_on(&actor, &builtin());
        let weak = actor.weak_self.clone();
        actor
            .preload_scene_with(scene(&builtin(), "basalt"), |handle, desc| {
                assert!(!desc.paused);
                assert!(desc.audio_muted);
                let mut runtime = SceneRuntime::windowless_for_test(
                    handle,
                    desc,
                    &SceneRuntimeState::try_from(desc)?,
                    weak,
                )?;
                runtime.presented_for_test = true;
                Ok(runtime)
            })
            .unwrap();
        actor
            .preload_scene_with(scene(&builtin(), "basalt"), |_, _| {
                panic!("already prepared")
            })
            .unwrap();
        actor
            .preload_scene_with(scene(&builtin(), "aurora"), |_, _| panic!("already live"))
            .unwrap();
        assert_eq!(running_on(&actor, &builtin()), before);
        let preloaded = parked_on(&actor, &builtin())[0].1;
        actor.finish_scene_preload(preloaded, false).unwrap();
        assert!(parked_on(&actor, &builtin())[0].2);
        facade.forget();
        facade
            .update(&mut actor, |model| {
                model.apply_reconcile(&[scene(&builtin(), "basalt")])
            })
            .unwrap();
        assert!(facade.jobs.borrow().is_empty());
        assert_eq!(running_on(&actor, &builtin()).1, preloaded);
        actor.finish_scene_preload(preloaded, true).unwrap();
        assert_eq!(
            running_on(&actor, &builtin()).1,
            preloaded,
            "late timeout cannot close a promoted scene"
        );
        actor.set_parked_scenes(1, Vec::new()).unwrap();
        assert!(parked_on(&actor, &builtin()).is_empty());
    }

    #[test]
    fn released_targets_are_not_opened() {
        let mut actor = two_displays();
        actor
            .preload_scene_with(scene(&builtin(), "basalt"), |_, _| panic!("not retained"))
            .unwrap();
    }

    #[test]
    fn a_preload_that_never_draws_is_released_without_affecting_the_live_wallpaper() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let _context = runtime.enter();
        let mut actor = two_displays();
        let facade = RuntimeFacade::default();
        actor
            .set_parked_scenes(1, vec![path("aurora"), path("basalt")])
            .unwrap();
        show(&mut actor, &facade, &builtin(), "aurora");
        let before = running_on(&actor, &builtin());
        let weak = actor.weak_self.clone();
        actor
            .preload_scene_with(scene(&builtin(), "basalt"), |handle, desc| {
                SceneRuntime::windowless_for_test(
                    handle,
                    desc,
                    &SceneRuntimeState::try_from(desc)?,
                    weak,
                )
            })
            .unwrap();
        let pending = parked_on(&actor, &builtin())[0].1;
        actor.finish_scene_preload(pending, true).unwrap();
        assert!(parked_on(&actor, &builtin()).is_empty());
        assert_eq!(running_on(&actor, &builtin()), before);
    }
}
