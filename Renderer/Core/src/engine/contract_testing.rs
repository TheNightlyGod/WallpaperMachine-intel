use super::{FirstFrameCallback, FirstFrameCallbackCell};

/// Non-native access to the genuine callback cell for bridge contract tests.
/// Available only through the explicit development test feature.
#[derive(Clone, Default)]
pub struct FirstFrameSlot {
    cell: FirstFrameCallbackCell,
}

impl FirstFrameSlot {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn install(&self, callback: FirstFrameCallback) {
        self.cell.set(callback);
    }

    #[must_use]
    pub fn renderer_callback(&self) -> FirstFrameCallback {
        self.cell.callback()
    }
}
