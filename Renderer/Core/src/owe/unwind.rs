// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
use std::{
    any::Any,
    ffi::CStr,
    panic::{AssertUnwindSafe, catch_unwind},
};

use crate::{EngineError, owe::sys};

const GENERIC_FAILURE: &str = "open-wallpaper-engine failed";
const UNKNOWN_PAYLOAD: &str = "unknown unwind payload";

/// The text of an unwind payload: a `String` or `&str` verbatim, anything else generic.
fn payload_text(payload: &(dyn Any + Send)) -> String {
    if let Some(text) = payload.downcast_ref::<String>() {
        text.clone()
    } else if let Some(text) = payload.downcast_ref::<&str>() {
        (*text).to_owned()
    } else {
        UNKNOWN_PAYLOAD.to_owned()
    }
}

pub struct UnwindSafeFFI {
    operation: &'static str,
}

impl UnwindSafeFFI {
    #[must_use]
    pub fn new(operation: &'static str) -> Self {
        Self { operation }
    }

    /// # Safety
    ///
    /// The caller must ensure that the OWE backend is properly initialized
    /// before calling this function, as it may involve FFI calls that
    /// require a valid OWE context.
    #[must_use]
    pub unsafe fn last_error() -> String {
        let read = catch_unwind(AssertUnwindSafe(|| unsafe { sys::owe_last_error() }));
        match read {
            Ok(text) if text.is_null() => GENERIC_FAILURE.to_owned(),
            Ok(text) => {
                let text = unsafe { CStr::from_ptr(text) }.to_string_lossy();
                if text.is_empty() {
                    GENERIC_FAILURE.to_owned()
                } else {
                    text.into_owned()
                }
            }
            Err(payload) => format!(
                "open-wallpaper-engine unwound while reading its last error: {}",
                payload_text(payload.as_ref())
            ),
        }
    }

    /// # Safety
    ///
    /// The caller must ensure the closure performs only FFI operations whose
    /// ABI permits unwinding across the boundary and that all raw pointers
    /// passed to the closure are valid for the duration of the call.
    ///
    /// # Errors
    ///
    /// Returns [`EngineError::Crash`] when the wrapped FFI call unwinds.
    pub unsafe fn call<T>(self, call: impl FnOnce() -> T) -> Result<T, EngineError> {
        catch_unwind(AssertUnwindSafe(call)).map_err(|payload| {
            EngineError::Crash(format!(
                "open-wallpaper-engine unwound while calling {}: {}",
                self.operation,
                payload_text(payload.as_ref())
            ))
        })
    }
}

pub mod testing {
    use crate::EngineError;

    /// # Errors
    ///
    /// Always returns [`EngineError::Crash`] when unwind catching works.
    pub fn panic_across_c_unwind_for_testing() -> Result<i32, EngineError> {
        extern "C-unwind" fn forced_panic() -> i32 {
            panic!("test ffi unwind");
        }

        // SAFETY: the callee only panics; no raw pointers are involved.
        unsafe { super::UnwindSafeFFI::new("test ffi").call(|| forced_panic()) }
    }
}
