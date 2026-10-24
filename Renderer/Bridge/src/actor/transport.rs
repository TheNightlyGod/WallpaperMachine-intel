use std::future::Future;
use std::sync::Arc;

use kameo::actor::{ActorRef, Spawn, WeakActorRef};
use kameo::error::SendError;
use kameo::message::Message;
use kameo::reply::Reply;
use tokio::runtime::{Builder, Handle, Runtime};

use crate::actor::bridge::{BridgeActor, assemble_actor};
use crate::actor::state::BridgeActorState;
use crate::api::{BridgeError, MousePollingControl};
use crate::config::ConfigStore;
use crate::engine::{EngineFacade, LoadJournal};
use crate::login::LaunchAtLoginController;
use crate::paths::BridgePaths;

/// A bridge's actor reference and runtime share one final-owner destructor.
/// Cloning this handle does not require the engine itself to implement Clone.
pub struct BridgeActorHandle<E: EngineFacade> {
    owner: Arc<RuntimeOwner<E>>,
}

struct RuntimeOwner<E: EngineFacade> {
    actor: ActorRef<BridgeActor<E>>,
    // Option permits consuming Runtime in Drop without a blocking Runtime::drop.
    runtime: Option<Runtime>,
}

impl<E: EngineFacade> Drop for RuntimeOwner<E> {
    fn drop(&mut self) {
        // The actor thread can retain its own mailbox reference. Merely dropping
        // our reference or shutting down Tokio does not terminate that thread.
        // This is an abort fallback, not the public graceful scene shutdown.
        self.actor.kill();
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown_background();
        }
    }
}

impl<E: EngineFacade> Clone for BridgeActorHandle<E> {
    fn clone(&self) -> Self {
        Self {
            owner: Arc::clone(&self.owner),
        }
    }
}

impl<E: EngineFacade> BridgeActorHandle<E> {
    pub fn spawn(
        state: BridgeActorState,
        engine: E,
        config_store: Option<ConfigStore>,
        launch_at_login: LaunchAtLoginController,
        paths: BridgePaths,
        mouse_polling: Arc<MousePollingControl>,
        load_journal: LoadJournal,
    ) -> Result<Self, BridgeError> {
        let runtime = Builder::new_multi_thread()
            .enable_all()
            .thread_name("wallpaper-bridge-actor-runtime")
            .build()
            .map_err(|error| {
                BridgeError::engine(format!("Failed to create bridge runtime: {error}"))
            })?;

        let actor = {
            let _entered = runtime.enter();
            let actor = assemble_actor(
                state,
                engine,
                config_store,
                launch_at_login,
                paths,
                mouse_polling,
                load_journal,
            );
            BridgeActor::spawn_in_thread(actor)
        };

        Ok(Self {
            owner: Arc::new(RuntimeOwner {
                actor,
                runtime: Some(runtime),
            }),
        })
    }

    pub async fn ask<M, T>(&self, message: M) -> Result<T, BridgeError>
    where
        BridgeActor<E>: Message<M>,
        <BridgeActor<E> as Message<M>>::Reply: Reply<Ok = T, Error = BridgeError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        self.owner.actor.ask(message).await.map_err(send_error)
    }

    pub fn blocking_ask<M, T>(&self, message: M) -> Result<T, BridgeError>
    where
        BridgeActor<E>: Message<M>,
        <BridgeActor<E> as Message<M>>::Reply: Reply<Ok = T, Error = BridgeError>,
        M: Send + 'static,
        T: Send + 'static,
    {
        self.owner
            .actor
            .ask(message)
            .blocking_send()
            .map_err(send_error)
    }

    /// Spawn before awaiting so the caller's executor never drives the supplied
    /// future directly. Join errors include panics and runtime cancellation.
    pub async fn run_on_runtime<F, T>(&self, future: F) -> Result<T, BridgeError>
    where
        F: Future<Output = T> + Send + 'static,
        T: Send + 'static,
    {
        self.runtime_handle()?
            .spawn(future)
            .await
            .map_err(|error| BridgeError::engine(format!("Bridge runtime task failed: {error}")))
    }

    pub(crate) fn weak_actor(&self) -> WeakActorRef<BridgeActor<E>> {
        self.owner.actor.downgrade()
    }

    /// A Tokio handle does not own RuntimeOwner and cannot create an owner cycle.
    pub(crate) fn runtime_handle(&self) -> Result<Handle, BridgeError> {
        self.owner
            .runtime
            .as_ref()
            .map(|runtime| runtime.handle().clone())
            .ok_or_else(|| BridgeError::engine("Bridge runtime has been released"))
    }

    #[cfg(test)]
    pub(crate) fn runtime_probe(&self) -> RuntimeDropProbe<E> {
        RuntimeDropProbe {
            owner: Arc::downgrade(&self.owner),
        }
    }
}

fn send_error<M>(error: SendError<M, BridgeError>) -> BridgeError {
    match error {
        SendError::HandlerError(error) => error,
        error => BridgeError::engine(format!("Bridge actor transport failed: {error}")),
    }
}

/// Observes owner reachability only; it does not certify native shutdown.
#[cfg(test)]
pub(crate) struct RuntimeDropProbe<E: EngineFacade> {
    owner: std::sync::Weak<RuntimeOwner<E>>,
}

#[cfg(test)]
impl<E: EngineFacade> Clone for RuntimeDropProbe<E> {
    fn clone(&self) -> Self {
        Self {
            owner: self.owner.clone(),
        }
    }
}

#[cfg(test)]
impl<E: EngineFacade> RuntimeDropProbe<E> {
    pub(crate) fn is_released(&self) -> bool {
        self.owner.strong_count() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Barrier;
    use std::time::Duration;

    use crate::api::BridgeErrorKind;
    use crate::api::lifecycle_test_support::inert_login_controller;
    use crate::api::mounted_lifecycle::ControlledEngine;
    use crate::login::LaunchAtLoginStatus;

    const DEADLINE: Duration = Duration::from_secs(10);

    fn fixture() -> (tempfile::TempDir, BridgeActorHandle<ControlledEngine>) {
        let root = tempfile::tempdir().expect("create owned transport test home");
        let handle = BridgeActorHandle::spawn(
            BridgeActorState::default(),
            ControlledEngine::new(Vec::new()),
            None,
            inert_login_controller(LaunchAtLoginStatus::Unavailable),
            BridgePaths::for_home(root.path()),
            Arc::new(MousePollingControl::new()),
            LoadJournal::open(None, "actor-transport-test"),
        )
        .expect("spawn actual bridge actor");
        (root, handle)
    }

    fn host_runtime() -> Runtime {
        Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("create independent host executor")
    }

    async fn assert_actor_released(weak: WeakActorRef<BridgeActor<ControlledEngine>>) {
        // Observing shutdown does not retain the runtime owner. Drop the
        // temporary actor observer before checking that mailbox owners leave.
        tokio::time::timeout(DEADLINE, async {
            if let Some(actor) = weak.upgrade() {
                actor.wait_for_shutdown().await;
                assert!(!actor.is_alive(), "actor remained alive after shutdown");
                drop(actor);
            }
            while weak.strong_count() != 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("actual actor must terminate and release mailbox ownership");
    }

    #[test]
    fn surviving_clone_keeps_actor_and_runtime_usable() {
        let (_root, handle) = fixture();
        let survivor = handle.clone();
        let probe = handle.runtime_probe();
        let weak = handle.weak_actor();
        drop(handle);
        assert!(!probe.is_released());
        let actor = weak.upgrade().expect("surviving handle retains actor");
        assert!(actor.is_alive());
        drop(actor);

        host_runtime().block_on(async {
            let value = tokio::time::timeout(DEADLINE, survivor.run_on_runtime(async { 42 }))
                .await
                .expect("surviving runtime makes progress")
                .expect("surviving task succeeds");
            assert_eq!(value, 42);
            drop(survivor);
            assert!(probe.is_released());
            assert_actor_released(weak).await;
        });
    }

    #[test]
    fn simultaneous_final_drops_release_actor_and_runtime_owner() {
        let (_root, handle) = fixture();
        let other = handle.clone();
        let probe = handle.runtime_probe();
        let second_probe = probe.clone();
        let weak = handle.weak_actor();
        let barrier = Arc::new(Barrier::new(2));
        let other_barrier = Arc::clone(&barrier);
        let (finished_tx, finished_rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            other_barrier.wait();
            drop(other);
            finished_tx.send(()).expect("host is still waiting");
        });

        // One contender is an entered host executor thread. Runtime::drop here
        // would panic; the final-owner destructor must use shutdown_background.
        host_runtime().block_on(async {
            barrier.wait();
            drop(handle);
            finished_rx
                .recv_timeout(DEADLINE)
                .expect("other drop must finish without blocking on runtime shutdown");
            worker.join().expect("concurrent drop must not panic");
            assert!(probe.is_released());
            assert!(second_probe.is_released());
            assert_actor_released(weak).await;
        });
    }

    #[test]
    fn timer_future_runs_on_bridge_runtime_not_host_executor() {
        let (_root, handle) = fixture();
        let weak = handle.weak_actor();
        let probe = handle.runtime_probe();
        let host_thread = std::thread::current().id();
        host_runtime().block_on(async {
            let task_thread = tokio::time::timeout(
                DEADLINE,
                handle.run_on_runtime(async {
                    // Construct the timer inside the submitted future, not on
                    // the host, to exercise the bridge's enabled timer driver.
                    tokio::time::sleep(Duration::from_millis(1)).await;
                    std::thread::current().id()
                }),
            )
            .await
            .expect("bridge timer must complete under host timeout")
            .expect("bridge timer task succeeds");
            assert_ne!(task_thread, host_thread);
            drop(handle);
            assert!(probe.is_released());
            assert_actor_released(weak).await;
        });
    }

    #[test]
    fn task_panic_is_an_engine_error_and_runtime_survives() {
        let (_root, handle) = fixture();
        let weak = handle.weak_actor();
        let probe = handle.runtime_probe();
        host_runtime().block_on(async {
            let error = tokio::time::timeout(
                DEADLINE,
                handle.run_on_runtime(async {
                    panic!("transport task panic sentinel");
                }),
            )
            .await
            .expect("panicking task must return a join result")
            .expect_err("panic cannot be reported as success");
            assert!(matches!(error.kind(), BridgeErrorKind::Engine));
            assert!(error.message().contains("transport task panic sentinel"));
            let value = tokio::time::timeout(DEADLINE, handle.run_on_runtime(async { 7 }))
                .await
                .expect("runtime must still make progress after panic")
                .expect("later task succeeds");
            assert_eq!(value, 7);
            drop(handle);
            assert!(probe.is_released());
            assert_actor_released(weak).await;
        });
    }
}
