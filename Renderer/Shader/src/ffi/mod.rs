// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! The C ABI (spec A 2.2 and 2.3, R1 to R9, R20, R70, R89 to R93): thirteen unmangled `rs_shader_*`
//! functions the C++ engine calls, behind the `ffi` feature. `include/rs_shader.h` declares exactly
//! this surface.
//!
//! Everything the engine reads is built when the compile returns and then never changes: the
//! handle owns NUL-terminated copies of the stage texts and the response documents, so every
//! accessor hands out a borrowed pointer that stays valid, and the same, until the handle is
//! freed (R5). Failures are the text of a [`ShaderError`], kept per thread (R70). No panic crosses
//! the boundary: a bug-induced panic becomes an ordinary failure (R4).
//!
//! This module is the only unsafe code of the crate. Each unsafe block says what it relies on.

use std::cell::{Cell, RefCell};
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::panic::{self, AssertUnwindSafe};
use std::ptr;
use std::sync::{LazyLock, Once};

use crate::diagnostic::diagnostics_json;
use crate::error::ShaderError;
use crate::identity::compiler_identity;
use crate::include::{IncludeError, IncludeErrorKind, InvalidPathClass};
use crate::pipeline::{CompiledProgram, compile};
use crate::request_json::parse_request_bytes;
use crate::source::IncludeSource;

#[cfg(test)]
mod tests;

/// Status of `rs_shader_compile_program` on success.
pub const RS_SHADER_OK: c_int = 0;
/// Status of `rs_shader_compile_program` on failure.
pub const RS_SHADER_ERROR: c_int = 1;
/// Stage kind of a vertex stage.
pub const RS_SHADER_STAGE_VERTEX: c_int = 0;
/// Stage kind of a fragment stage.
pub const RS_SHADER_STAGE_FRAGMENT: c_int = 1;
/// Returned for a null handle or an index out of range, for kind and target alike.
pub const RS_SHADER_INVALID: c_int = -1;
/// The only target a stage can have. The value 0 was the Vulkan-style target of an earlier
/// library: it is retired, never returned and never to be given another meaning (R111).
pub const RS_SHADER_TARGET_METAL: c_int = 1;

/// The host's keep-alive entry (R113). The thirteen `rs_shader_*` functions are called only from the
/// engine's C++, so a Rust host that links this crate as an rlib must name one of them for the
/// linker to keep the object that holds them all. The host calls this once from its backend
/// initialisation. It returns the address of the compile entry (a non-zero number the caller
/// ignores) and does nothing else; it is Rust-internal and not part of the C interface.
pub fn keep_exports_alive() -> usize {
    std::hint::black_box(rs_shader_compile_program as unsafe extern "C" fn(_, _, _, _) -> c_int) as usize
}

/// What `rs_shader_last_error` reads before any compile on a thread and after a successful one.
const NO_ERROR_TEXT: &str = "no shader error";

/// Bytes an include provider hands over. Mirrored field for field by the engine (2.3).
#[repr(C)]
pub struct RsShaderOwnedBytes {
    /// `NULL` with `len == 0` is "no such include"; `NULL` with `len != 0` is a provider fault.
    pub ptr: *mut u8,
    pub len: usize,
    /// Releases the buffer; called once, after the bytes were copied, when it and `ptr` are non-null.
    pub free: Option<unsafe extern "C" fn(*mut u8, usize, *mut c_void)>,
    pub free_user_data: *mut c_void,
}

/// The include provider: `path` is the directive's path with backslashes turned into slashes.
pub type RsShaderIncludeCallback = Option<unsafe extern "C" fn(*const c_char, *mut c_void) -> RsShaderOwnedBytes>;

struct StageOut {
    kind: c_int,
    msl: CString,
    json: CString,
}

/// A compiled program, opaque to C (the header declares only the incomplete type).
#[repr(C)]
pub struct RsShaderProgram {
    stages: Vec<StageOut>,
    metadata: CString,
    reflection: CString,
    diagnostics: CString,
    cache_key: CString,
}

/// A string for C: a NUL that would end the text early becomes a space (R5).
fn c_string(text: impl Into<Vec<u8>>) -> CString {
    let mut bytes: Vec<u8> = text.into();
    for b in &mut bytes {
        if *b == 0 {
            *b = b' ';
        }
    }
    CString::new(bytes).expect("every NUL was replaced")
}

fn build_program(compiled: &CompiledProgram) -> Result<RsShaderProgram, ShaderError> {
    let stages = compiled
        .stages
        .iter()
        .map(|stage| StageOut {
            kind: stage.kind.abi_value(),
            msl: c_string(stage.payload.msl_source.as_str()),
            json: c_string(stage.payload.to_json()),
        })
        .collect();
    Ok(RsShaderProgram {
        stages,
        metadata: c_string(compiled.metadata.to_json()?),
        #[cfg(not(feature = "observer-uniform-layout"))]
        reflection: c_string(compiled.reflection.to_json()),
        #[cfg(feature = "observer-uniform-layout")]
        reflection: c_string(crate::observer_uniform_layout::reflection_json(compiled)),
        diagnostics: c_string(diagnostics_json(&compiled.diagnostics)),
        cache_key: c_string(compiled.cache_key.as_str()),
    })
}

// ---------------------------------------------------------------------------------------------
// The last error (R70)

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(c_string(NO_ERROR_TEXT));
    /// True while this thread is inside a compile: the panic hook stays quiet then (R93), because
    /// the panic is turned into a failure text and the layer writes nothing to standard streams.
    static IN_COMPILE: Cell<bool> = const { Cell::new(false) };
}

fn set_last_error(text: &str) {
    let text = c_string(text);
    // A thread that is being torn down has no buffer any more; there is nobody to read it.
    let _ = LAST_ERROR.try_with(|slot| *slot.borrow_mut() = text);
}

/// Last error text for the calling thread.
///
/// Reads `no shader error` before any compile on the thread and after a successful one. The
/// pointer is valid until the same thread's next `rs_shader_compile_program` call.
#[unsafe(no_mangle)]
pub extern "C" fn rs_shader_last_error() -> *const c_char {
    LAST_ERROR
        .try_with(|slot| slot.borrow().as_ptr())
        .unwrap_or(c"no shader error".as_ptr())
}

// ---------------------------------------------------------------------------------------------
// Panic containment (R4, R93)

/// Silences the default panic message for panics raised inside a compile and passes every other
/// panic to the hook that was installed before. Installed once, on the first compile.
fn install_quiet_hook() {
    static INSTALL: Once = Once::new();
    INSTALL.call_once(|| {
        let previous = panic::take_hook();
        panic::set_hook(Box::new(move |info| {
            if !IN_COMPILE.try_with(Cell::get).unwrap_or(false) {
                previous(info);
            }
        }));
    });
}

/// Runs `work` with panics turned into failure text.
fn contained<T>(work: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
    install_quiet_hook();
    let outer = IN_COMPILE.with(|flag| flag.replace(true));
    let outcome = panic::catch_unwind(AssertUnwindSafe(work));
    IN_COMPILE.with(|flag| flag.set(outer));
    match outcome {
        Ok(result) => result,
        Err(payload) => Err(ShaderError::from_panic(payload).to_string()),
    }
}

#[cfg(test)]
thread_local! {
    /// Test hook: the next compile on this thread panics with this message once the request was read.
    pub(crate) static FORCE_PANIC: Cell<Option<&'static str>> = const { Cell::new(None) };
}

// ---------------------------------------------------------------------------------------------
// The include provider (R17 to R22, 2.3)

/// Releases a provider's buffer exactly once, whatever happens to the copy (R20).
struct OwnedBuffer(RsShaderOwnedBytes);

impl Drop for OwnedBuffer {
    fn drop(&mut self) {
        if let Some(free) = self.0.free
            && !self.0.ptr.is_null()
        {
            // SAFETY: the provider supplied this routine for this buffer; the buffer is released
            // once, here, and nothing reads it afterwards.
            unsafe { free(self.0.ptr, self.0.len, self.0.free_user_data) };
        }
    }
}

struct CallbackSource {
    callback: RsShaderIncludeCallback,
    user_data: *mut c_void,
}

impl IncludeSource for CallbackSource {
    fn read(&self, path: &str) -> Result<String, IncludeError> {
        let error = |kind| IncludeError { path: path.to_string(), kind };
        let Some(callback) = self.callback else {
            return Err(error(IncludeErrorKind::NotFound));
        };
        // The preprocessor rejects such a path before it asks; a C string cannot carry one anyway.
        let c_path =
            CString::new(path).map_err(|_| error(IncludeErrorKind::InvalidPath(InvalidPathClass::ContainsNul)))?;
        // SAFETY: the engine's callback contract (2.3): called here, on the calling thread, with a
        // NUL-terminated path that outlives the call and the user data the caller supplied.
        let owned = OwnedBuffer(unsafe { callback(c_path.as_ptr(), self.user_data) });
        if owned.0.ptr.is_null() {
            return Err(error(if owned.0.len == 0 {
                IncludeErrorKind::NotFound
            } else {
                IncludeErrorKind::Unreadable { len: owned.0.len }
            }));
        }
        if owned.0.len > isize::MAX as usize {
            return Err(error(IncludeErrorKind::Unreadable { len: owned.0.len }));
        }
        // SAFETY: a non-null pointer with a length the provider promises is readable; the bytes are
        // copied now and the buffer is only released when `owned` drops, after this copy.
        let bytes = unsafe { std::slice::from_raw_parts(owned.0.ptr, owned.0.len) }.to_vec();
        String::from_utf8(bytes).map_err(|_| error(IncludeErrorKind::NotUtf8))
    }
}

// ---------------------------------------------------------------------------------------------
// Compile

/// Compiles one program (R1 to R4).
///
/// Returns 0 and writes a handle to `*out_program` when the whole program compiled; returns 1
/// otherwise, with the thread's last error describing why and a null handle in `*out_program`
/// (when that pointer is non-null).
///
/// # Safety
/// `request_json` is null or a NUL-terminated string; `out_program` is null or writable;
/// `callback`, when set, honours the include contract with `cb_user_data`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rs_shader_compile_program(
    request_json: *const c_char,
    callback: RsShaderIncludeCallback,
    cb_user_data: *mut c_void,
    out_program: *mut *mut RsShaderProgram,
) -> c_int {
    if !out_program.is_null() {
        // SAFETY: the caller promised a writable pointer; null first, so no early return leaves
        // the previous content (possibly a dangling handle) behind (R1).
        unsafe { *out_program = ptr::null_mut() };
    }
    let outcome = contained(|| {
        if request_json.is_null() {
            return Err("compile request failed: the request pointer is null".to_string());
        }
        if out_program.is_null() {
            return Err("compile request failed: the out program pointer is null".to_string());
        }
        // SAFETY: non-null and NUL-terminated by the caller's promise; read before any other work.
        let bytes = unsafe { CStr::from_ptr(request_json) }.to_bytes();
        let request = parse_request_bytes(bytes).map_err(|e| ShaderError::from(e).to_string())?;
        #[cfg(test)]
        if let Some(message) = FORCE_PANIC.with(Cell::take) {
            panic!("{message}");
        }
        let source = CallbackSource { callback, user_data: cb_user_data };
        let compiled = compile(&request, &source).map_err(|e| e.to_string())?;
        build_program(&compiled).map_err(|e| e.to_string())
    });
    match outcome {
        Ok(program) => {
            set_last_error(NO_ERROR_TEXT);
            // Success already implies a non-null `out_program`; the check is repeated so the write
            // carries its own guard.
            if !out_program.is_null() {
                // SAFETY: non-null and writable by the caller's promise.
                unsafe { *out_program = Box::into_raw(Box::new(program)) };
            }
            RS_SHADER_OK
        }
        Err(text) => {
            set_last_error(&text);
            RS_SHADER_ERROR
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Accessors (R5 to R7)

fn program<'a>(handle: *const RsShaderProgram) -> Option<&'a RsShaderProgram> {
    // SAFETY: null is checked by `as_ref`; a live handle is the caller's promise, and the handle
    // is immutable after creation, so shared references from many threads are sound.
    unsafe { handle.as_ref() }
}

fn stage<'a>(handle: *const RsShaderProgram, index: usize) -> Option<&'a StageOut> {
    program(handle)?.stages.get(index)
}

/// Number of stages: 2 on success, 0 for a null handle.
///
/// # Safety
/// `program` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rs_shader_program_stage_count(program_handle: *const RsShaderProgram) -> usize {
    program(program_handle).map_or(0, |p| p.stages.len())
}

/// Kind of stage `index`: 0 vertex, 1 fragment, -1 for a null handle or a bad index.
///
/// # Safety
/// `program` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rs_shader_program_stage_kind(program_handle: *const RsShaderProgram, index: usize) -> c_int {
    stage(program_handle, index).map_or(RS_SHADER_INVALID, |s| s.kind)
}

/// Target of stage `index`: 1 for Metal, -1 for a null handle or a bad index.
///
/// # Safety
/// `program` is null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rs_shader_program_stage_target(program_handle: *const RsShaderProgram, index: usize) -> c_int {
    stage(program_handle, index).map_or(RS_SHADER_INVALID, |_| RS_SHADER_TARGET_METAL)
}

/// The Metal source of stage `index`; `""` for a null handle or a bad index.
///
/// # Safety
/// `program` is null or a live handle; the pointer is valid until the handle is freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rs_shader_program_stage_msl_source(
    program_handle: *const RsShaderProgram,
    index: usize,
) -> *const c_char {
    stage(program_handle, index).map_or(c"".as_ptr(), |s| s.msl.as_ptr())
}

/// The payload JSON of stage `index`; `{}` for a null handle or a bad index.
///
/// # Safety
/// `program` is null or a live handle; the pointer is valid until the handle is freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rs_shader_program_stage_metal_json(
    program_handle: *const RsShaderProgram,
    index: usize,
) -> *const c_char {
    stage(program_handle, index).map_or(c"{}".as_ptr(), |s| s.json.as_ptr())
}

/// The metadata JSON; `{}` for a null handle.
///
/// # Safety
/// `program` is null or a live handle; the pointer is valid until the handle is freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rs_shader_program_metadata_json(program_handle: *const RsShaderProgram) -> *const c_char {
    program(program_handle).map_or(c"{}".as_ptr(), |p| p.metadata.as_ptr())
}

/// The reflection JSON; `{}` for a null handle.
///
/// # Safety
/// `program` is null or a live handle; the pointer is valid until the handle is freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rs_shader_program_reflection_json(program_handle: *const RsShaderProgram) -> *const c_char {
    program(program_handle).map_or(c"{}".as_ptr(), |p| p.reflection.as_ptr())
}

/// The diagnostics JSON array; `[]` for a null handle.
///
/// # Safety
/// `program` is null or a live handle; the pointer is valid until the handle is freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rs_shader_program_diagnostics_json(program_handle: *const RsShaderProgram) -> *const c_char {
    program(program_handle).map_or(c"[]".as_ptr(), |p| p.diagnostics.as_ptr())
}

/// The program's cache key; `""` for a null handle.
///
/// # Safety
/// `program` is null or a live handle; the pointer is valid until the handle is freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rs_shader_program_cache_key(program_handle: *const RsShaderProgram) -> *const c_char {
    program(program_handle).map_or(c"".as_ptr(), |p| p.cache_key.as_ptr())
}

/// Releases a handle. Null does nothing; any thread may free a handle.
///
/// # Safety
/// `program` is null or a handle this library returned and that was not freed yet. Nothing may
/// use the handle or a pointer borrowed from it afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rs_shader_program_free(program_handle: *mut RsShaderProgram) {
    if !program_handle.is_null() {
        // SAFETY: the handle came from `Box::into_raw` in `rs_shader_compile_program` and, by the
        // caller's promise, is released once.
        drop(unsafe { Box::from_raw(program_handle) });
    }
}

/// The compiler identity for persistent caches (4.11); a process-lifetime pointer.
#[unsafe(no_mangle)]
pub extern "C" fn rs_shader_cache_identity() -> *const c_char {
    static IDENTITY: LazyLock<CString> = LazyLock::new(|| c_string(compiler_identity()));
    IDENTITY.as_ptr()
}
