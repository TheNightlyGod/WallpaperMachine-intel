//! What lets a test bridge's threads go when its test ends.
//!
//! The bridge registers a callback with its engine that holds the bridge's actor
//! and its runtime, and the actor holds the engine in turn. A test bridge that is
//! merely dropped therefore keeps the runtime's workers and the actor's own thread
//! (about one per CPU core, twenty on an 18-core Mac) until the whole test process
//! exits, and the bridge suite sits close to the threads a process may hold. A test
//! that builds a bridge over a [`FakeEngineFacade`] keeps an [`EngineRelease`] for
//! that engine, which drops the callback when the test is over and so closes the loop.

use std::sync::Arc;

use crate::engine::{EngineFacade as _, FakeEngineFacade};

/// Replaces the first-frame callback the bridge registered with a no-op when it goes
/// out of scope, whichever order the test's bridge and release are dropped in.
pub(super) struct EngineRelease(FakeEngineFacade);

impl EngineRelease {
    /// A release for the engine a test hands to its bridge. Cloning the engine only
    /// shares the fake; the bridge and the release see the same callbacks.
    pub(super) fn of(engine: &FakeEngineFacade) -> Self {
        Self(engine.clone())
    }
}

impl Drop for EngineRelease {
    fn drop(&mut self) {
        self.0.set_first_frame_callback(Arc::new(|_| {}));
    }
}
