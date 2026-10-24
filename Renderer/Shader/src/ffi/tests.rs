// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// In-crate checks of the parts of the C ABI an outside caller cannot reach: a forced internal
// failure and the panic containment bookkeeping (R4, R93). Everything else is exercised through
// the exported functions in `tests/ffi_abi.rs`.

use std::ffi::{CStr, CString};
use std::ptr;

use super::*;

const MINIMAL: &str = r#"{"shader_name":"t","stages":[
 {"kind":"vertex","source":"attribute vec3 a_Position; void main(){ gl_Position = vec4(a_Position, 1.0); }"},
 {"kind":"fragment","source":"void main(){ gl_FragColor = vec4(1.0); }"}]}"#;

unsafe fn compile_text(text: &str, out: *mut *mut RsShaderProgram) -> c_int {
    let request = CString::new(text).unwrap();
    unsafe { rs_shader_compile_program(request.as_ptr(), None, ptr::null_mut(), out) }
}

fn last_error() -> String {
    unsafe { CStr::from_ptr(rs_shader_last_error()) }.to_str().unwrap().to_string()
}

#[test]
fn an_internal_panic_becomes_a_failure_and_the_next_call_works() {
    let mut out: *mut RsShaderProgram = ptr::dangling_mut::<RsShaderProgram>();
    FORCE_PANIC.with(|f| f.set(Some("forced for the test")));
    let status = unsafe { compile_text(MINIMAL, &mut out) };
    assert_eq!(status, RS_SHADER_ERROR);
    assert!(out.is_null(), "no handle on failure");
    let text = last_error();
    assert!(text.contains("failed internally") && text.contains("forced for the test"), "{text}");
    assert!(!IN_COMPILE.with(Cell::get), "the quiet flag is restored after a panic");

    let status = unsafe { compile_text(MINIMAL, &mut out) };
    assert_eq!(status, RS_SHADER_OK, "{}", last_error());
    assert!(!out.is_null());
    assert_eq!(last_error(), "no shader error");
    unsafe { rs_shader_program_free(out) };
}

#[test]
fn a_panic_with_a_payload_that_is_not_text_still_fails_cleanly() {
    let result: Result<(), String> = contained(|| std::panic::panic_any(7u32));
    assert_eq!(result.unwrap_err(), "the shader layer failed internally");
}

#[test]
fn contained_restores_the_flag_of_an_outer_compile() {
    let _ = contained(|| {
        assert!(IN_COMPILE.with(Cell::get));
        let inner: Result<(), String> = contained(|| Err("inner".into()));
        assert_eq!(inner.unwrap_err(), "inner");
        assert!(IN_COMPILE.with(Cell::get), "still inside the outer compile");
        Ok(())
    });
    assert!(!IN_COMPILE.with(Cell::get));
}

#[test]
fn text_for_c_never_carries_a_nul() {
    assert_eq!(c_string("a\0b\0").to_bytes(), b"a b ");
}

/// R93: a panic inside a compile prints nothing. The default hook writes to standard error, so
/// the check runs a copy of this test binary and reads what that process wrote.
#[test]
fn a_contained_panic_writes_nothing_to_standard_streams() {
    const CHILD: &str = "WM_SHADER_PANIC_CHILD";
    if std::env::var_os(CHILD).is_some() {
        // The child: force the panic, check the failure, and let the process end normally.
        let mut out = ptr::null_mut();
        FORCE_PANIC.with(|f| f.set(Some("child panic")));
        assert_eq!(unsafe { compile_text(MINIMAL, &mut out) }, RS_SHADER_ERROR);
        assert!(last_error().contains("child panic"));
        return;
    }
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "ffi::tests::a_contained_panic_writes_nothing_to_standard_streams", "--nocapture", "--test-threads=1"])
        .env(CHILD, "1")
        .output()
        .expect("the test binary starts again");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{stderr}");
    assert!(!stderr.contains("panicked"), "the hook was not quiet: {stderr}");
    assert!(!String::from_utf8_lossy(&output.stdout).contains("child panic"));
}

#[test]
fn the_keep_alive_entry_names_the_compile_function_and_is_not_part_of_the_c_interface() {
    let address = keep_exports_alive();
    assert_ne!(address, 0);
    assert_eq!(address, keep_exports_alive(), "the same address every time");
    assert_eq!(address, rs_shader_compile_program as unsafe extern "C" fn(_, _, _, _) -> c_int as usize);
    // Exactly one such entry: a second function that names exports would be a second thing to keep in step.
    let source = include_str!("mod.rs");
    assert_eq!(source.matches("as unsafe extern \"C\" fn(_, _, _, _) -> c_int) as usize").count(), 1);
    // And it carries no export attribute: the archive's symbol list stays at the thirteen.
    let at = source.find("pub fn keep_exports_alive").unwrap();
    assert!(!source[at - 40..at].contains("no_mangle"));
}
