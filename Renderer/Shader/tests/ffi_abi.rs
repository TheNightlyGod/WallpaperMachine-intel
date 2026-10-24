// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// The C ABI exercised the way a C caller does: raw pointers, NUL-terminated text, a callback
// that hands over buffers with a free routine, handles passed between threads. Written from the
// behaviour list of spec A section 8 (ABI and ownership, request validation, includes, threading).

#![cfg(feature = "ffi")]

use std::alloc::{Layout, alloc, dealloc};
use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::ptr;
use std::thread::{self, ThreadId};

use wm_shader::ffi::*;
use wm_shader::json::{self, Value};

// ------------------------------------------------------------------------------------------
// Programs and requests

const VERTEX: &str = "\
attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
uniform mat4 g_ModelViewProjectionMatrix;
void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
";

const FRAGMENT: &str = "\
varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
";

const MINIMAL_VERTEX: &str = "attribute vec3 a_Position; void main() { gl_Position = vec4(a_Position, 1.0); }";
const MINIMAL_FRAGMENT: &str = "void main() { gl_FragColor = vec4(0.25, 0.5, 0.75, 1.0); }";

fn stage_json(kind: &str, source: &str) -> String {
    format!(r#"{{"kind":"{kind}","source":{}}}"#, json::string(source))
}

/// A request document with the stages in the given order and `extra` members appended.
fn request_with(vertex: &str, fragment: &str, fragment_first: bool, extra: &str) -> String {
    let v = stage_json("vertex", vertex);
    let f = stage_json("fragment", fragment);
    let stages = if fragment_first { format!("{f},{v}") } else { format!("{v},{f}") };
    format!(r#"{{"shader_name":"test\\shader","stages":[{stages}]{extra}}}"#)
}

fn request(vertex: &str, fragment: &str) -> String {
    request_with(vertex, fragment, false, "")
}

fn minimal() -> String {
    request(MINIMAL_VERTEX, MINIMAL_FRAGMENT)
}

fn textured() -> String {
    request_with(VERTEX, FRAGMENT, false, r#","textures":[{"slot":0,"enabled":true,"format":"rgba8"}]"#)
}

// ------------------------------------------------------------------------------------------
// Calling helpers

/// The result of a compile call: the handle (null on failure) and the status.
struct Compiled {
    status: c_int,
    handle: *mut RsShaderProgram,
}

unsafe impl Send for Compiled {}

impl Drop for Compiled {
    fn drop(&mut self) {
        unsafe { rs_shader_program_free(self.handle) };
    }
}

fn text_of(p: *const c_char) -> String {
    assert!(!p.is_null(), "accessors never return null");
    unsafe { CStr::from_ptr(p) }.to_str().expect("UTF-8").to_string()
}

fn last_error() -> String {
    text_of(rs_shader_last_error())
}

fn compile_plain(request: &str) -> Compiled {
    compile_with(request, None, ptr::null_mut())
}

fn compile_with(request: &str, callback: RsShaderIncludeCallback, user_data: *mut c_void) -> Compiled {
    let request = CString::new(request).unwrap();
    // A non-null sentinel proves a failing call overwrites the out pointer.
    let mut out = ptr::dangling_mut::<RsShaderProgram>();
    let status = unsafe { rs_shader_compile_program(request.as_ptr(), callback, user_data, &mut out) };
    if status != RS_SHADER_OK {
        assert!(out.is_null(), "a failure writes a null handle");
    }
    Compiled { status, handle: out }
}

fn ok(request: &str) -> Compiled {
    let c = compile_plain(request);
    assert_eq!(c.status, RS_SHADER_OK, "{}", last_error());
    assert!(!c.handle.is_null());
    c
}

fn failure(request: &str) -> String {
    let c = compile_plain(request);
    assert_eq!(c.status, RS_SHADER_ERROR, "expected a failure");
    assert!(c.handle.is_null());
    last_error()
}

impl Compiled {
    fn msl(&self, i: usize) -> String {
        text_of(unsafe { rs_shader_program_stage_msl_source(self.handle, i) })
    }
    fn stage_doc(&self, i: usize) -> Value {
        parse(&text_of(unsafe { rs_shader_program_stage_metal_json(self.handle, i) }))
    }
    fn metadata(&self) -> Value {
        parse(&text_of(unsafe { rs_shader_program_metadata_json(self.handle) }))
    }
    fn reflection(&self) -> Value {
        parse(&text_of(unsafe { rs_shader_program_reflection_json(self.handle) }))
    }
    fn diagnostics(&self) -> Value {
        parse(&text_of(unsafe { rs_shader_program_diagnostics_json(self.handle) }))
    }
    fn key(&self) -> String {
        text_of(unsafe { rs_shader_program_cache_key(self.handle) })
    }
}

fn parse(text: &str) -> Value {
    json::parse(text).unwrap_or_else(|e| panic!("not JSON ({e}): {text}"))
}

fn member<'a>(v: &'a Value, key: &str) -> &'a Value {
    match v {
        Value::Object(members) => members.iter().find(|(k, _)| k == key).map(|(_, v)| v).unwrap_or_else(|| panic!("no key {key}")),
        other => panic!("not an object: {other:?}"),
    }
}

fn keys(v: &Value) -> Vec<&str> {
    match v {
        Value::Object(members) => members.iter().map(|(k, _)| k.as_str()).collect(),
        other => panic!("not an object: {other:?}"),
    }
}

fn items(v: &Value) -> &[Value] {
    match v {
        Value::Array(items) => items,
        other => panic!("not an array: {other:?}"),
    }
}

fn string_of(v: &Value) -> &str {
    match v {
        Value::String(s) => s,
        other => panic!("not a string: {other:?}"),
    }
}

// ------------------------------------------------------------------------------------------
// The include provider the tests play the engine with

enum Reply {
    /// Bytes with a free routine.
    Owned(Vec<u8>),
    /// Bytes without a free routine (nothing may be freed).
    Unowned(Vec<u8>),
    NotFound,
    /// A null pointer with a non-zero length.
    Fault(usize),
    /// A non-null pointer with a zero length.
    Empty,
}

/// One provider: replies by path, a log of calls and of frees, the thread it was called on.
struct Env {
    replies: HashMap<String, Reply>,
    calls: RefCell<Vec<String>>,
    frees: RefCell<Vec<(usize, usize)>>,
    handed_out: RefCell<Vec<(usize, usize)>>,
    threads: RefCell<Vec<ThreadId>>,
}

impl Env {
    fn new(replies: Vec<(&str, Reply)>) -> Env {
        Env {
            replies: replies.into_iter().map(|(p, r)| (p.to_string(), r)).collect(),
            calls: RefCell::default(),
            frees: RefCell::default(),
            handed_out: RefCell::default(),
            threads: RefCell::default(),
        }
    }

    fn compile(&self, request: &str) -> Compiled {
        compile_with(request, Some(provider), self as *const Env as *mut c_void)
    }

    fn calls(&self) -> Vec<String> {
        self.calls.borrow().clone()
    }

    fn frees(&self) -> usize {
        self.frees.borrow().len()
    }
}

fn owned_buffer(bytes: &[u8]) -> *mut u8 {
    let layout = Layout::from_size_align(bytes.len().max(1), 1).unwrap();
    unsafe {
        let p = alloc(layout);
        assert!(!p.is_null());
        ptr::copy_nonoverlapping(bytes.as_ptr(), p, bytes.len());
        p
    }
}

/// Poisons the buffer, then releases it: a layer that read it afterwards would see 0xFF.
unsafe extern "C" fn release(ptr: *mut u8, len: usize, user_data: *mut c_void) {
    let env = unsafe { &*(user_data as *const Env) };
    env.frees.borrow_mut().push((ptr as usize, len));
    unsafe {
        ptr::write_bytes(ptr, 0xFF, len);
        dealloc(ptr, Layout::from_size_align(len.max(1), 1).unwrap());
    }
}

unsafe extern "C" fn provider(path: *const c_char, user_data: *mut c_void) -> RsShaderOwnedBytes {
    let env = unsafe { &*(user_data as *const Env) };
    let path = unsafe { CStr::from_ptr(path) }.to_str().unwrap().to_string();
    env.calls.borrow_mut().push(path.clone());
    env.threads.borrow_mut().push(thread::current().id());
    let none = RsShaderOwnedBytes { ptr: ptr::null_mut(), len: 0, free: None, free_user_data: ptr::null_mut() };
    match env.replies.get(&path) {
        None | Some(Reply::NotFound) => none,
        Some(Reply::Fault(len)) => RsShaderOwnedBytes { len: *len, ..none },
        Some(Reply::Empty) => {
            let p = owned_buffer(&[]);
            env.handed_out.borrow_mut().push((p as usize, 0));
            RsShaderOwnedBytes { ptr: p, len: 0, free: Some(release), free_user_data: user_data }
        }
        Some(Reply::Owned(bytes)) => {
            let p = owned_buffer(bytes);
            env.handed_out.borrow_mut().push((p as usize, bytes.len()));
            RsShaderOwnedBytes { ptr: p, len: bytes.len(), free: Some(release), free_user_data: user_data }
        }
        Some(Reply::Unowned(bytes)) => {
            // Env owns this buffer throughout the synchronous compile; the library only reads it.
            RsShaderOwnedBytes { ptr: bytes.as_ptr().cast_mut(), len: bytes.len(), free: None, free_user_data: ptr::null_mut() }
        }
    }
}

// ------------------------------------------------------------------------------------------
// ABI and ownership (R1 to R9)

#[test]
fn a_minimal_request_compiles_and_every_document_parses() {
    let c = ok(&minimal());
    assert_eq!(unsafe { rs_shader_program_stage_count(c.handle) }, 2);
    for (i, kind) in [(0usize, 0), (1, 1)] {
        assert_eq!(unsafe { rs_shader_program_stage_kind(c.handle, i) }, kind);
        assert_eq!(unsafe { rs_shader_program_stage_target(c.handle, i) }, 1);
        let msl = c.msl(i);
        assert!(!msl.is_empty() && msl.contains("#include <metal_stdlib>"), "{msl}");
        let doc = c.stage_doc(i);
        assert!(!string_of(member(&doc, "entry_point")).is_empty());
        assert_eq!(string_of(member(&doc, "language_version")), "2.0");
        assert!(msl.contains(string_of(member(&doc, "entry_point"))));
        let conventions = member(&doc, "conventions");
        for flag in ["clip_space_y_flipped", "clip_space_depth_remapped", "texture_origin_flipped"] {
            assert_eq!(member(conventions, flag), &Value::Bool(false), "{flag}");
        }
        let _ = items(member(&doc, "bindings"));
    }
    assert!(!c.key().is_empty());
    assert!(c.key().bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.'));
    assert_eq!(last_error(), "no shader error");
    // the author's constant reaches the output
    assert!(c.msl(1).contains("0.25"), "{}", c.msl(1));
}

#[test]
fn the_response_documents_are_compact_and_keyed_in_the_documented_order() {
    let c = ok(&textured());
    let text = |p: *const c_char| text_of(p);
    let docs = [
        text(unsafe { rs_shader_program_stage_metal_json(c.handle, 0) }),
        text(unsafe { rs_shader_program_metadata_json(c.handle) }),
        text(unsafe { rs_shader_program_reflection_json(c.handle) }),
        text(unsafe { rs_shader_program_diagnostics_json(c.handle) }),
    ];
    for doc in &docs {
        // No whitespace between tokens: outside of strings there is none at all.
        let mut in_string = false;
        let mut escaped = false;
        for ch in doc.chars() {
            if in_string {
                match (escaped, ch) {
                    (true, _) => escaped = false,
                    (false, '\\') => escaped = true,
                    (false, '"') => in_string = false,
                    _ => {}
                }
            } else if ch == '"' {
                in_string = true;
            } else {
                assert!(!ch.is_whitespace(), "whitespace outside a string in {doc}");
            }
        }
    }
    assert_eq!(keys(&c.stage_doc(0)), ["entry_point", "language_version", "bindings", "conventions"]);
    assert_eq!(
        keys(&c.metadata()),
        ["combos", "aliases", "default_uniforms", "default_textures", "active_texture_slots"]
    );
    #[cfg(not(feature = "observer-uniform-layout"))]
    assert_eq!(
        keys(&c.reflection()),
        ["descriptor_bindings", "uniform_blocks", "vertex_inputs", "active_texture_slots"]
    );
    #[cfg(feature = "observer-uniform-layout")]
    assert_eq!(
        keys(&c.reflection()),
        ["descriptor_bindings", "uniform_blocks", "vertex_inputs", "active_texture_slots", "observer_uniform_layout"]
    );
    let diagnostics = c.diagnostics();
    for entry in items(&diagnostics) {
        assert_eq!(keys(entry), ["stage", "pass", "span", "message", "generated_source_path"]);
    }
}

#[test]
fn reflection_and_metadata_describe_a_textured_quad() {
    let c = ok(&textured());
    let reflection = c.reflection();
    let names: Vec<&str> = items(member(&reflection, "descriptor_bindings")).iter().map(|d| string_of(member(d, "name"))).collect();
    assert!(names.contains(&"g_Texture0") && names.contains(&"GlobalUniforms"), "{names:?}");
    let blocks = items(member(&reflection, "uniform_blocks"));
    assert_eq!(blocks.len(), 1);
    assert_eq!(string_of(member(&blocks[0], "name")), "GlobalUniforms");
    let inputs: Vec<&str> = items(member(&reflection, "vertex_inputs")).iter().map(|d| string_of(member(d, "name"))).collect();
    assert!(inputs.contains(&"a_Position") && inputs.contains(&"a_TexCoord"), "{inputs:?}");
    let slots = member(&reflection, "active_texture_slots");
    assert_eq!(slots, member(&c.metadata(), "active_texture_slots"));
    assert_eq!(items(slots).len(), 1);
    // a minimal reader of the keys the engine requires (R94)
    for stage in 0..2 {
        for binding in items(member(&c.stage_doc(stage), "bindings")) {
            for key in ["name", "set", "binding", "slot_kind", "slot"] {
                member(binding, key);
            }
        }
    }
    // success diagnostics: one Codegen entry per stage, no source text
    let diagnostics = c.diagnostics();
    let codegen = items(&diagnostics).iter().filter(|d| member(d, "pass") == &Value::String("Codegen".into())).count();
    assert_eq!(codegen, 2);
}

#[test]
fn a_reversed_stage_order_is_followed() {
    let c = ok(&request_with(MINIMAL_VERTEX, MINIMAL_FRAGMENT, true, ""));
    assert_eq!(unsafe { rs_shader_program_stage_kind(c.handle, 0) }, 1);
    assert_eq!(unsafe { rs_shader_program_stage_kind(c.handle, 1) }, 0);
    assert!(c.msl(0).contains("0.25"), "stage 0 is the fragment");
    assert!(c.msl(1).contains("a_Position") || !c.msl(1).contains("0.25"));
}

#[test]
fn invalid_json_fails_with_json_in_the_text() {
    for text in ["", "{", "not json", "[]", "{\"shader_name\":1}", "{\"stages\":[]}", "null"] {
        let c = compile_plain(text);
        assert_eq!(c.status, RS_SHADER_ERROR, "{text:?}");
        assert!(c.handle.is_null());
        assert!(last_error().to_lowercase().contains("json"), "{text:?}: {}", last_error());
    }
}

#[test]
fn null_pointers_fail_without_crashing() {
    let request = CString::new(minimal()).unwrap();
    unsafe {
        let status = rs_shader_compile_program(ptr::null(), None, ptr::null_mut(), ptr::null_mut());
        assert_eq!(status, RS_SHADER_ERROR);
        assert!(last_error().contains("request pointer"), "{}", last_error());

        let mut out = ptr::dangling_mut::<RsShaderProgram>();
        let status = rs_shader_compile_program(ptr::null(), None, ptr::null_mut(), &mut out);
        assert_eq!(status, RS_SHADER_ERROR);
        assert!(out.is_null(), "an early failure still nulls the out pointer");
        assert!(last_error().contains("request pointer"));

        let status = rs_shader_compile_program(request.as_ptr(), None, ptr::null_mut(), ptr::null_mut());
        assert_eq!(status, RS_SHADER_ERROR);
        assert!(last_error().contains("out program pointer"), "{}", last_error());
    }
}

#[test]
fn a_request_that_is_not_utf8_fails() {
    let mut bytes = br#"{"shader_name":"x","stages":[]}"#.to_vec();
    bytes.splice(2..2, [0xFFu8, 0xFE]);
    let request = CString::new(bytes).unwrap();
    let mut out = ptr::null_mut();
    let status = unsafe { rs_shader_compile_program(request.as_ptr(), None, ptr::null_mut(), &mut out) };
    assert_eq!(status, RS_SHADER_ERROR);
    assert!(out.is_null());
    assert!(last_error().contains("UTF-8"), "{}", last_error());
}

#[test]
fn accessors_of_a_null_handle_and_a_bad_index_return_the_documented_values() {
    unsafe {
        let null: *const RsShaderProgram = ptr::null();
        assert_eq!(rs_shader_program_stage_count(null), 0);
        assert_eq!(rs_shader_program_stage_kind(null, 0), -1);
        assert_eq!(rs_shader_program_stage_target(null, 0), -1);
        assert_eq!(text_of(rs_shader_program_stage_msl_source(null, 0)), "");
        assert_eq!(text_of(rs_shader_program_stage_metal_json(null, 0)), "{}");
        assert_eq!(text_of(rs_shader_program_metadata_json(null)), "{}");
        assert_eq!(text_of(rs_shader_program_reflection_json(null)), "{}");
        assert_eq!(text_of(rs_shader_program_diagnostics_json(null)), "[]");
        assert_eq!(text_of(rs_shader_program_cache_key(null)), "");
        rs_shader_program_free(ptr::null_mut());

        let c = ok(&minimal());
        for bad in [2usize, 3, 1000, usize::MAX] {
            assert_eq!(rs_shader_program_stage_kind(c.handle, bad), -1);
            assert_eq!(rs_shader_program_stage_target(c.handle, bad), -1);
            assert_eq!(text_of(rs_shader_program_stage_msl_source(c.handle, bad)), "");
            assert_eq!(text_of(rs_shader_program_stage_metal_json(c.handle, bad)), "{}");
        }
    }
}

#[test]
fn borrowed_pointers_are_stable_until_the_handle_is_freed() {
    let c = ok(&textured());
    unsafe {
        let first = [
            rs_shader_program_stage_msl_source(c.handle, 0),
            rs_shader_program_stage_msl_source(c.handle, 1),
            rs_shader_program_stage_metal_json(c.handle, 0),
            rs_shader_program_stage_metal_json(c.handle, 1),
            rs_shader_program_metadata_json(c.handle),
            rs_shader_program_reflection_json(c.handle),
            rs_shader_program_diagnostics_json(c.handle),
            rs_shader_program_cache_key(c.handle),
        ];
        let copies: Vec<String> = first.iter().map(|p| text_of(*p)).collect();
        // Other compiles on this thread, and other handles, change nothing about this one.
        let other = ok(&minimal());
        let _ = failure("{");
        let second = [
            rs_shader_program_stage_msl_source(c.handle, 0),
            rs_shader_program_stage_msl_source(c.handle, 1),
            rs_shader_program_stage_metal_json(c.handle, 0),
            rs_shader_program_stage_metal_json(c.handle, 1),
            rs_shader_program_metadata_json(c.handle),
            rs_shader_program_reflection_json(c.handle),
            rs_shader_program_diagnostics_json(c.handle),
            rs_shader_program_cache_key(c.handle),
        ];
        assert_eq!(first, second, "the same pointers on every call");
        for (p, copy) in second.iter().zip(&copies) {
            assert_eq!(&text_of(*p), copy);
        }
        drop(other);
    }
    // Every text is NUL-terminated exactly once (R5).
    assert!(!c.msl(0).contains('\0'));
}

#[test]
fn a_handle_can_be_freed_by_another_thread_and_read_by_many() {
    let c = ok(&textured());
    let addr = c.handle as usize;
    thread::scope(|scope| {
        let readers: Vec<_> = (0..4)
            .map(|_| {
                scope.spawn(move || {
                    let handle = addr as *const RsShaderProgram;
                    let mut total = 0;
                    for _ in 0..50 {
                        total += unsafe { CStr::from_ptr(rs_shader_program_stage_msl_source(handle, 1)) }.to_bytes().len();
                        total += unsafe { CStr::from_ptr(rs_shader_program_reflection_json(handle)) }.to_bytes().len();
                    }
                    total
                })
            })
            .collect();
        let totals: Vec<usize> = readers.into_iter().map(|h| h.join().unwrap()).collect();
        assert!(totals.iter().all(|t| *t == totals[0] && *t > 0));
    });
    let sent = Compiled { status: c.status, handle: c.handle };
    std::mem::forget(c);
    thread::spawn(move || drop(sent)).join().unwrap();
}

#[test]
fn the_last_error_follows_the_calling_thread() {
    // Initial text on a thread that never compiled.
    thread::spawn(|| assert_eq!(last_error(), "no shader error")).join().unwrap();

    let _ = failure("{");
    let failed = last_error();
    assert!(failed.to_lowercase().contains("json"));
    // Accessors, identity and free never change it.
    let c = ok(&minimal());
    drop(c);
    assert_eq!(last_error(), "no shader error", "a success resets it");
    let _ = failure("{");
    let c = {
        let request = CString::new(minimal()).unwrap();
        let mut out = ptr::null_mut();
        // a failure, then queries, must keep the failure text
        unsafe { rs_shader_compile_program(ptr::null(), None, ptr::null_mut(), &mut out) };
        request
    };
    let before = last_error();
    unsafe {
        rs_shader_program_free(ptr::null_mut());
        let _ = rs_shader_program_stage_count(ptr::null());
    }
    let _ = rs_shader_cache_identity();
    assert_eq!(last_error(), before);
    drop(c);

    // Two failures in a row, then a success: the second call's text replaces the first's.
    let _ = failure("{");
    let _ = failure(&request(MINIMAL_VERTEX, MINIMAL_VERTEX));
    assert!(!last_error().to_lowercase().contains("json parse"));

    // Another thread's compile does not change this thread's text.
    let mine = last_error();
    thread::spawn(|| {
        let _ = failure(r#"{"shader_name":"x","stages":[]}"#);
    })
    .join()
    .unwrap();
    assert_eq!(last_error(), mine);
}

#[test]
fn the_cache_identity_is_a_stable_process_lifetime_string() {
    let a = rs_shader_cache_identity();
    let b = rs_shader_cache_identity();
    assert_eq!(a, b);
    let text = text_of(a);
    assert!(!text.is_empty());
    let from_thread = thread::spawn(|| rs_shader_cache_identity() as usize).join().unwrap();
    assert_eq!(from_thread, a as usize, "one string for the process");
    assert_eq!(text, wm_shader::identity::compiler_identity());
}

#[test]
fn a_compile_is_a_pure_function_of_the_request() {
    let reference = ok(&textured());
    let want: Vec<String> = vec![
        reference.msl(0),
        reference.msl(1),
        text_of(unsafe { rs_shader_program_stage_metal_json(reference.handle, 0) }),
        text_of(unsafe { rs_shader_program_metadata_json(reference.handle) }),
        text_of(unsafe { rs_shader_program_reflection_json(reference.handle) }),
        text_of(unsafe { rs_shader_program_diagnostics_json(reference.handle) }),
        reference.key(),
    ];
    thread::scope(|scope| {
        for _ in 0..8 {
            scope.spawn(|| {
                for _ in 0..25 {
                    let c = ok(&textured());
                    let got = vec![
                        c.msl(0),
                        c.msl(1),
                        text_of(unsafe { rs_shader_program_stage_metal_json(c.handle, 0) }),
                        text_of(unsafe { rs_shader_program_metadata_json(c.handle) }),
                        text_of(unsafe { rs_shader_program_reflection_json(c.handle) }),
                        text_of(unsafe { rs_shader_program_diagnostics_json(c.handle) }),
                        c.key(),
                    ];
                    assert_eq!(got, want);
                }
            });
        }
    });
}

// ------------------------------------------------------------------------------------------
// Request validation (R10 to R16)

fn with_extra(extra: &str) -> String {
    request_with(MINIMAL_VERTEX, MINIMAL_FRAGMENT, false, extra)
}

#[test]
fn every_rejection_names_the_offending_value() {
    let name_request = |name: &str| {
        format!(
            r#"{{"shader_name":{},"stages":[{},{}]}}"#,
            json::string(name),
            stage_json("vertex", MINIMAL_VERTEX),
            stage_json("fragment", MINIMAL_FRAGMENT)
        )
    };
    let cases: Vec<(String, &str)> = vec![
        (name_request(""), "shader name is empty"),
        (name_request("a\0b"), "shader name"),
        (
            format!(r#"{{"shader_name":"x","stages":[{}]}}"#, stage_json("vertex", MINIMAL_VERTEX)),
            "missing fragment stage",
        ),
        (
            format!(r#"{{"shader_name":"x","stages":[{}]}}"#, stage_json("fragment", MINIMAL_FRAGMENT)),
            "missing vertex stage",
        ),
        (
            format!(
                r#"{{"shader_name":"x","stages":[{},{},{}]}}"#,
                stage_json("vertex", MINIMAL_VERTEX),
                stage_json("vertex", MINIMAL_VERTEX),
                stage_json("fragment", MINIMAL_FRAGMENT)
            ),
            "duplicate vertex stage",
        ),
        (r#"{"shader_name":"x","stages":[]}"#.to_string(), "stage"),
        (
            r#"{"shader_name":"x","stages":[{"kind":"geometry","source":""}]}"#.to_string(),
            "geometry",
        ),
        (with_extra(r#","combos":[{"name":"Mode","value":"1"},{"name":"MODE","value":"2"}]"#), "duplicate combo name"),
        (with_extra(r#","combos":[{"name":"1A","value":"1"}]"#), "1A"),
        (with_extra(r#","combos":[{"name":"A-B","value":"1"}]"#), "A-B"),
        (with_extra(r#","combos":[{"name":"","value":"1"}]"#), "combo"),
        (with_extra(r#","textures":[{"slot":32,"enabled":true}]"#), "32"),
        (with_extra(r#","textures":[{"slot":300,"enabled":true}]"#), "300"),
        (
            with_extra(r#","textures":[{"slot":3,"enabled":true},{"slot":3,"enabled":false}]"#),
            "duplicate texture slot 3",
        ),
        (with_extra(r#","textures":[{"slot":0}]"#), "enabled"),
        (with_extra(r#","properties":[{"name":"speed","value":{"kind":"none"}}]"#), "property `speed` has no value"),
        (
            with_extra(r#","cache_policy":{"mode":"disabled"},"cache_strategy":{"mode":"disabled"}"#),
            "cache_",
        ),
        (with_extra(r#","cache_policy":{"mode":"enabled"}"#), "scene_id"),
        (with_extra(r#","cache_policy":{"mode":"sometimes"}"#), "sometimes"),
        (with_extra(r#","target":"vulkan_spirv""#), "vulkan_spirv"),
        (with_extra(r#","target":"dx12""#), "dx12"),
    ];
    for (request, expected) in cases {
        let c = compile_plain(&request);
        assert_eq!(c.status, RS_SHADER_ERROR, "expected a failure mentioning {expected:?}: {request}");
        let text = last_error();
        assert!(text.contains(expected), "expected {expected:?} in {text:?}");
    }
}

#[test]
fn optional_fields_default_and_unknown_keys_are_ignored() {
    // explicit target, both spellings of the cache policy, extra keys at every level
    let request = format!(
        r#"{{"shader_name":"x","target":"metal_msl","future":{{"a":[1]}},
            "cache_strategy":{{"mode":"enabled","scene_id":"s","x":1}},
            "stages":[{{"kind":"vertex","source":{},"extra":true}},{{"kind":"fragment","source":{},"extra":null}}],
            "combos":[{{"name":"Mode","value":"1","note":"x"}}],
            "textures":[{{"slot":9,"enabled":false,"unknown":1}}],
            "properties":[{{"name":"p","value":{{"kind":"vec2","value":[1,2]}},"future":0}}]}}"#,
        json::string(MINIMAL_VERTEX),
        json::string(MINIMAL_FRAGMENT)
    );
    let c = ok(&request);
    let metadata = c.metadata();
    // a request combo is not echoed back (R54)
    assert!(items(member(&metadata, "combos")).is_empty());
    let policy = ok(&with_extra(r#","cache_policy":{"mode":"enabled","scene_id":"s"}"#));
    assert_eq!(ok(&minimal()).key(), ok(&with_extra(r#","cache_policy":{"mode":"disabled"}"#)).key());
    assert_ne!(policy.key(), ok(&minimal()).key());
    // a record for a slot the shader never declares is accepted and changes only the key
    let record = ok(&with_extra(r#","textures":[{"slot":5,"enabled":true}]"#));
    assert_ne!(record.key(), ok(&minimal()).key());
    assert_eq!(record.msl(0), ok(&minimal()).msl(0));
}

#[test]
fn a_reachable_failure_never_leaves_the_library_unusable() {
    let broken = request(MINIMAL_VERTEX, "void main() { gl_FragColor = ; }");
    let text = failure(&broken);
    assert!(text.contains("fragment") || text.contains("Fragment"), "{text}");
    assert!(!text.contains('\u{1b}'), "no terminal colour codes");
    // backslashes of the shader name became slashes (R10)
    assert!(text.contains("test/shader") && !text.contains("test\\shader"), "{text}");
    let _ = ok(&minimal());
}

// ------------------------------------------------------------------------------------------
// Includes (R17 to R22)

const INCLUDING_FRAGMENT: &str = "#include \"common/colors.h\"\nvoid main() { gl_FragColor = MY_COLOR; }\n";

#[test]
fn an_include_is_resolved_through_the_callback_and_its_buffer_is_freed_once() {
    let env = Env::new(vec![(
        "common/colors.h",
        Reply::Owned(b"#define MY_COLOR vec4(0.125, 0.5, 0.75, 1.0)\n".to_vec()),
    )]);
    // backslashes are normalised before the callback sees them
    let fragment = "#include \"common\\colors.h\"\nvoid main() { gl_FragColor = MY_COLOR; }\n";
    let c = env.compile(&request(MINIMAL_VERTEX, fragment));
    assert_eq!(c.status, RS_SHADER_OK, "{}", last_error());
    assert!(c.msl(1).contains("0.125"), "{}", c.msl(1));
    assert_eq!(env.calls(), ["common/colors.h"]);
    assert_eq!(env.frees(), 1);
    let handed = env.handed_out.borrow()[0];
    assert_eq!(env.frees.borrow()[0], handed, "freed with the same pointer and length");
    let me = thread::current().id();
    assert!(env.threads.borrow().iter().all(|t| *t == me), "the callback runs on the calling thread");
}

#[test]
fn a_path_is_requested_at_most_once_per_compile() {
    let env = Env::new(vec![("a.h", Reply::Owned(b"#define A 1\n".to_vec()))]);
    let fragment = "#include \"a.h\"\n#include \"a.h\"\nvoid main() { gl_FragColor = vec4(float(A)); }\n";
    let c = env.compile(&request(MINIMAL_VERTEX, fragment));
    assert_eq!(c.status, RS_SHADER_OK, "{}", last_error());
    assert_eq!(env.calls(), ["a.h"]);
    // the same text from the vertex stage reads from the same compile: still once
    let both = request(
        "#include \"a.h\"\nattribute vec3 a_Position; void main() { gl_Position = vec4(a_Position, float(A)); }",
        fragment,
    );
    let env = Env::new(vec![("a.h", Reply::Owned(b"#define A 1\n".to_vec()))]);
    let c = env.compile(&both);
    assert_eq!(c.status, RS_SHADER_OK, "{}", last_error());
    assert_eq!(env.calls(), ["a.h"]);
    assert_eq!(env.frees(), 1);
}

#[test]
fn a_missing_include_on_an_active_path_names_the_path() {
    let env = Env::new(vec![("nope/x.h", Reply::NotFound)]);
    let c = env.compile(&request(MINIMAL_VERTEX, "#include \"nope/x.h\"\nvoid main() { gl_FragColor = vec4(1.0); }"));
    assert_eq!(c.status, RS_SHADER_ERROR);
    assert!(last_error().contains("nope/x.h"), "{}", last_error());
    assert_eq!(env.calls(), ["nope/x.h"]);
    assert_eq!(env.frees(), 0, "nothing was handed over, nothing to free");
}

#[test]
fn an_include_in_an_untaken_branch_is_never_requested() {
    let env = Env::new(vec![]);
    let fragment = "#if 0\n#include \"missing.h\"\n#endif\nvoid main() { gl_FragColor = vec4(1.0); }";
    let c = env.compile(&request(MINIMAL_VERTEX, fragment));
    assert_eq!(c.status, RS_SHADER_OK, "{}", last_error());
    assert!(env.calls().is_empty());
}

#[test]
fn without_a_callback_every_reached_include_is_not_found() {
    let c = compile_plain(&request(MINIMAL_VERTEX, INCLUDING_FRAGMENT));
    assert_eq!(c.status, RS_SHADER_ERROR);
    let text = last_error();
    assert!(text.contains("common/colors.h") && text.contains("not found"), "{text}");
    // ... and an unreached one is fine without a callback
    let c = compile_plain(&request(MINIMAL_VERTEX, "#if 0\n#include \"x.h\"\n#endif\nvoid main() { gl_FragColor = vec4(1.0); }"));
    assert_eq!(c.status, RS_SHADER_OK, "{}", last_error());
}

#[test]
fn an_empty_include_compiles() {
    let env = Env::new(vec![("empty.h", Reply::Empty)]);
    let fragment = "#include \"empty.h\"\nvoid main() { gl_FragColor = vec4(1.0); }";
    let c = env.compile(&request(MINIMAL_VERTEX, fragment));
    assert_eq!(c.status, RS_SHADER_OK, "{}", last_error());
    assert_eq!(env.frees(), 1, "an empty but non-null buffer is released");
    assert_eq!(env.frees.borrow()[0].1, 0);
}

#[test]
fn a_null_pointer_with_a_length_is_a_provider_fault() {
    let env = Env::new(vec![("bad.h", Reply::Fault(12))]);
    let fragment = "#include \"bad.h\"\nvoid main() { gl_FragColor = vec4(1.0); }";
    let c = env.compile(&request(MINIMAL_VERTEX, fragment));
    assert_eq!(c.status, RS_SHADER_ERROR);
    let text = last_error();
    assert!(text.contains("bad.h") && text.contains("null pointer") && text.contains("non-zero length"), "{text}");
    assert_eq!(env.frees(), 0, "a null pointer is never passed to free");
}

#[test]
fn bytes_that_are_not_utf8_are_an_error_and_still_freed_once() {
    let env = Env::new(vec![("bin.h", Reply::Owned(vec![0xFF, 0xFE, 0x41]))]);
    let fragment = "#include \"bin.h\"\nvoid main() { gl_FragColor = vec4(1.0); }";
    let c = env.compile(&request(MINIMAL_VERTEX, fragment));
    assert_eq!(c.status, RS_SHADER_ERROR);
    let text = last_error();
    assert!(text.contains("bin.h") && text.to_lowercase().contains("utf-8"), "{text}");
    assert_eq!(env.frees(), 1);
}

#[test]
fn a_provider_without_a_free_routine_is_never_freed() {
    let env = Env::new(vec![("u.h", Reply::Unowned(b"#define U 1\n".to_vec()))]);
    let fragment = "#include \"u.h\"\nvoid main() { gl_FragColor = vec4(float(U)); }";
    let c = env.compile(&request(MINIMAL_VERTEX, fragment));
    assert_eq!(c.status, RS_SHADER_OK, "{}", last_error());
    assert_eq!(env.frees(), 0);
}

#[test]
fn buffers_are_freed_when_a_later_step_fails() {
    let env = Env::new(vec![("a.h", Reply::Owned(b"#define A 1\n".to_vec()))]);
    let fragment = "#include \"a.h\"\nvoid main() { gl_FragColor = ; }";
    let c = env.compile(&request(MINIMAL_VERTEX, fragment));
    assert_eq!(c.status, RS_SHADER_ERROR);
    assert_eq!(env.frees(), 1);
    // the bytes were copied before the release poisoned them: a retry with a fixed shader works
    let fixed = env.compile(&request(MINIMAL_VERTEX, "#include \"a.h\"\nvoid main() { gl_FragColor = vec4(float(A)); }"));
    assert_eq!(fixed.status, RS_SHADER_OK, "{}", last_error());
}

#[test]
fn an_include_cycle_names_the_chain_and_frees_every_buffer() {
    let env = Env::new(vec![
        ("a.h", Reply::Owned(b"#include \"b.h\"\n".to_vec())),
        ("b.h", Reply::Owned(b"#include \"a.h\"\n".to_vec())),
    ]);
    let fragment = "#include \"a.h\"\nvoid main() { gl_FragColor = vec4(1.0); }";
    let c = env.compile(&request(MINIMAL_VERTEX, fragment));
    assert_eq!(c.status, RS_SHADER_ERROR);
    let text = last_error();
    assert!(text.contains("a.h -> b.h -> a.h"), "{text}");
    assert_eq!(env.frees(), env.handed_out.borrow().len());
}

#[test]
fn invalid_paths_fail_before_the_callback_is_called() {
    for directive in [
        "#include \"../x.h\"",
        "#include \"a/../x.h\"",
        "#include \"/abs/x.h\"",
        "#include \"//server/x.h\"",
        "#include \"C:/x.h\"",
        "#include \"c:\\x.h\"",
        "#include \"\"",
        "#include <../x.h>",
        "#include </abs/x.h>",
        "#include <>",
    ] {
        let env = Env::new(vec![("x.h", Reply::Owned(b"".to_vec()))]);
        let fragment = format!("{directive}\nvoid main() {{ gl_FragColor = vec4(1.0); }}");
        let c = env.compile(&request(MINIMAL_VERTEX, &fragment));
        assert_eq!(c.status, RS_SHADER_ERROR, "{directive}");
        assert!(env.calls().is_empty(), "{directive}: the callback was called for {:?}", env.calls());
        let text = last_error();
        assert!(text.contains("include"), "{directive}: {text}");
    }
}

#[test]
fn an_include_directive_with_no_path_is_a_parse_failure() {
    let c = compile_plain(&request(MINIMAL_VERTEX, "#include\nvoid main() { gl_FragColor = vec4(1.0); }"));
    assert_eq!(c.status, RS_SHADER_ERROR);
    assert!(last_error().contains("#include expects a quoted include path"), "{}", last_error());
}

// ------------------------------------------------------------------------------------------
// Threads and resources (R89 to R93)

#[test]
fn concurrent_compiles_keep_their_results_and_their_error_text_apart() {
    thread::scope(|scope| {
        let handles: Vec<_> = (0..8)
            .map(|n| {
                scope.spawn(move || {
                    for round in 0..10 {
                        let marker = format!("0.{n}{round}5");
                        let fragment = format!("void main() {{ gl_FragColor = vec4({marker}, 0.0, 0.0, 1.0); }}");
                        let c = ok(&request(MINIMAL_VERTEX, &fragment));
                        assert!(c.msl(1).contains(&marker), "{marker}: {}", c.msl(1));
                        let own = format!("no_such_stage_{n}_{round}");
                        let bad = format!(
                            r#"{{"shader_name":"x","stages":[{{"kind":"vertex","source":"void main(){{}}"}}],"combos":[{{"name":"{own}","value":"1"}}]}}"#
                        );
                        let text = failure(&bad);
                        assert!(text.contains("missing fragment stage"), "{text}");
                    }
                })
            })
            .collect();
        for h in handles {
            h.join().unwrap();
        }
    });
}

#[test]
fn includes_run_on_the_calling_thread_of_each_concurrent_compile() {
    thread::scope(|scope| {
        for _ in 0..4 {
            scope.spawn(|| {
                let env = Env::new(vec![("a.h", Reply::Owned(b"#define A 1\n".to_vec()))]);
                let fragment = "#include \"a.h\"\nvoid main() { gl_FragColor = vec4(float(A)); }";
                for _ in 0..10 {
                    let c = env.compile(&request(MINIMAL_VERTEX, fragment));
                    assert_eq!(c.status, RS_SHADER_OK, "{}", last_error());
                }
                let me = thread::current().id();
                assert!(env.threads.borrow().iter().all(|t| *t == me));
                assert_eq!(env.frees(), 10);
            });
        }
    });
}

#[test]
fn hostile_nesting_fails_on_a_small_stack_without_crashing() {
    // 512 KiB is what a plain secondary thread gets on macOS (R91). An unoptimised build uses
    // many times more stack per call, so the default there is larger; the bound that matters is
    // the release one, which `WM_SHADER_TEST_STACK_KIB` can probe downwards.
    let kib: usize = std::env::var("WM_SHADER_TEST_STACK_KIB")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(if cfg!(debug_assertions) { 16 * 1024 } else { 512 });
    let handle = thread::Builder::new()
        .stack_size(kib * 1024)
        .spawn(|| {
            let parens = format!("float x = {}1.0{};", "(".repeat(1000), ")".repeat(1000));
            let deep_if = format!("{}{}", "#if 1\n".repeat(200), "#endif\n".repeat(200));
            // Nesting with no bracket to count: statements inside statements, and structures
            // inside structures (R91).
            let unbraced = |head: &str, n: usize| {
                format!("void main() {{ float x = 0.0; {}x = 1.0; gl_FragColor = vec4(x); }}", format!("{head} ").repeat(n))
            };
            let else_chain = format!(
                "void main() {{ float x = 0.0; if (x < 0.0) x = 1.0; {}gl_FragColor = vec4(x); }}",
                "else if (x < 5.0) x = 2.0; ".repeat(2000)
            );
            let do_nest = format!(
                "void main() {{ float x = 0.0; {}x = 1.0; {}gl_FragColor = vec4(x); }}",
                "do ".repeat(2000),
                "while (x < 1.0); ".repeat(2000)
            );
            let struct_chain = {
                let mut text = String::from("struct S0 { float a; };\n");
                for i in 1..3000 {
                    text.push_str(&format!("struct S{i} {{ S{} a; }};\n", i - 1));
                }
                text + "void main() { gl_FragColor = vec4(1.0); }"
            };
            let fragments = [
                format!("{parens}\nvoid main() {{ gl_FragColor = vec4(x); }}"),
                format!("{deep_if}void main() {{ gl_FragColor = vec4(1.0); }}"),
                format!("void main() {{ gl_FragColor = vec4({}1.0{}); }}", "(".repeat(5000), ")".repeat(5000)),
                unbraced("if (x < 5.0)", 2000),
                unbraced("for (;;)", 2000),
                unbraced("while (x < 1.0)", 2000),
                else_chain,
                do_nest,
                struct_chain,
            ];
            for fragment in &fragments {
                // The outcome (success or a failure text) does not matter; surviving does.
                let _ = compile_plain(&request(MINIMAL_VERTEX, fragment));
            }
            // 64 nested includes, then one more than the layer follows
            let mut replies: Vec<(String, Reply)> = Vec::new();
            for i in 0..100 {
                replies.push((format!("n{i}.h"), Reply::Owned(format!("#include \"n{}.h\"\n", i + 1).into_bytes())));
            }
            let env = Env {
                replies: replies.into_iter().collect(),
                calls: RefCell::default(),
                frees: RefCell::default(),
                handed_out: RefCell::default(),
                threads: RefCell::default(),
            };
            let c = env.compile(&request(MINIMAL_VERTEX, "#include \"n0.h\"\nvoid main() { gl_FragColor = vec4(1.0); }"));
            assert_eq!(c.status, RS_SHADER_ERROR);
            assert_eq!(env.frees(), env.handed_out.borrow().len());
            // and the layer is still usable
            let c = ok(&minimal());
            assert_eq!(c.status, RS_SHADER_OK);
        })
        .unwrap();
    handle.join().expect("no crash on a 512 KiB stack");
}

#[test]
fn the_deepest_nesting_the_guard_accepts_still_compiles_on_a_small_stack() {
    // The guard's budget is calibrated against the compiler's stack use: for each shape, the
    // largest nesting the measure lets through must be translated, not overflow (R91).
    let kib: usize = std::env::var("WM_SHADER_TEST_STACK_KIB")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(if cfg!(debug_assertions) { 16 * 1024 } else { 512 });
    let handle = thread::Builder::new()
        .stack_size(kib * 1024)
        .spawn(|| {
            use wm_shader::backend::depth::{STACK_BUDGET, STRUCT_DEPTH_LIMIT, stack_cost};
            let body = |inner: String| format!("void main() {{ float x = 0.0; {inner} gl_FragColor = vec4(x); }}");
            type Shape = (&'static str, Box<dyn Fn(usize) -> String>);
            let shapes: Vec<Shape> = vec![
                ("if", Box::new(move |n| body(format!("{}x = 1.0;", "if (x < 5.0) ".repeat(n))))),
                ("for", Box::new(move |n| body(format!("{}x = 1.0;", "for (int i = 0; i < 1; i++) ".repeat(n))))),
                ("while", Box::new(move |n| body(format!("{}x = 1.0;", "while (x < 0.0) ".repeat(n))))),
                ("do", Box::new(move |n| body(format!("{}x = 1.0; {}", "do ".repeat(n), "while (x < 0.0); ".repeat(n))))),
                ("else if", Box::new(move |n| body(format!("if (x < 0.0) x = 1.0; {}", "else if (x < 5.0) x = 2.0; ".repeat(n))))),
                ("blocks", Box::new(move |n| body(format!("{}x = 1.0;{}", "{ ".repeat(n), " }".repeat(n))))),
                ("braced if", Box::new(move |n| body(format!("{}x = 1.0;{}", "if (x < 5.0) { ".repeat(n), " }".repeat(n))))),
                ("parentheses", Box::new(move |n| body(format!("x = {}1.0{};", "(".repeat(n), ")".repeat(n))))),
                ("sum", Box::new(move |n| body(format!("x = {};", vec!["x"; n].join(" + "))))),
                (
                    "structs",
                    Box::new(move |n| {
                        let mut text = String::from("struct S0 { float a; };\n");
                        for i in 1..n {
                            text.push_str(&format!("struct S{i} {{ S{} a; }};\n", i - 1));
                        }
                        text + "void main() { gl_FragColor = vec4(1.0); }"
                    }),
                ),
            ];
            for (name, make) in &shapes {
                let accepted = |n: usize| {
                    let text = make(n);
                    stack_cost(&text) <= STACK_BUDGET && wm_shader::backend::depth::struct_depth(&text) <= STRUCT_DEPTH_LIMIT
                };
                let (mut low, mut high) = (1usize, 4000usize);
                assert!(accepted(low), "{name}");
                while low + 1 < high {
                    let mid = (low + high) / 2;
                    if accepted(mid) { low = mid } else { high = mid }
                }
                let c = compile_plain(&request(MINIMAL_VERTEX, &make(low)));
                // naga may still refuse a legal depth of its own (a status of error); surviving is the point.
                println!("{name}: accepted down to {low}, status {}", c.status);
            }
        })
        .unwrap();
    handle.join().expect("the deepest accepted nesting must not crash a small stack");
}

#[test]
fn a_response_read_by_a_minimal_reader_has_what_the_engine_requires() {
    let c = ok(&textured());
    let reflection = c.reflection();
    for d in items(member(&reflection, "descriptor_bindings")) {
        for key in ["name", "binding", "descriptor"] {
            member(d, key);
        }
    }
    for b in items(member(&reflection, "uniform_blocks")) {
        for key in ["name", "size"] {
            member(b, key);
        }
        for m in items(member(b, "members")) {
            for key in ["name", "offset", "size"] {
                member(m, key);
            }
        }
    }
    for v in items(member(&reflection, "vertex_inputs")) {
        for key in ["name", "location", "format"] {
            member(v, key);
        }
    }
}

#[test]
fn a_signature_the_header_does_not_declare_is_not_exported_by_the_module() {
    // The exported names of the C ABI, kept in one place so the header test can compare.
    let exported = [
        "rs_shader_compile_program",
        "rs_shader_program_stage_count",
        "rs_shader_program_stage_kind",
        "rs_shader_program_stage_target",
        "rs_shader_program_stage_msl_source",
        "rs_shader_program_stage_metal_json",
        "rs_shader_program_metadata_json",
        "rs_shader_program_reflection_json",
        "rs_shader_program_diagnostics_json",
        "rs_shader_program_cache_key",
        "rs_shader_program_free",
        "rs_shader_last_error",
        "rs_shader_cache_identity",
    ];
    let header = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/include/rs_shader.h")).unwrap();
    for name in exported {
        assert!(header.contains(&format!("{name}(")), "{name} is not declared in the header");
    }
    let declared: std::collections::BTreeSet<&str> = header
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .filter(|w| w.starts_with("rs_shader_") && header.contains(&format!("{w}(")))
        .collect();
    assert_eq!(declared.len(), exported.len(), "the header declares exactly the contract: {declared:?}");
    assert!(!header.contains("spv"), "no SPIR-V accessors");
}

// ------------------------------------------------------------------------------------------
// Amendment a-contract R111 and R77: the one target, and the identity string

#[test]
fn only_the_metal_target_exists() {
    // Every other spelling, the retired Vulkan one included, is a request error that names the
    // string and carries the request-parse marker of R16; it is never mapped or defaulted.
    for spelling in ["vulkan_spirv", "", "made_up_target", "Metal_MSL", "metal", "0", "vulkan_spirv "] {
        let request = with_extra(&format!(r#","target":{}"#, json::string(spelling)));
        let c = compile_plain(&request);
        assert_eq!(c.status, RS_SHADER_ERROR, "target {spelling:?} must be refused");
        assert!(c.handle.is_null());
        let text = last_error();
        assert!(text.contains("json request parse failed"), "{spelling:?}: {text}");
        // The exact string is in the text (for the empty one, as an empty pair of quotes or backticks).
        assert!(text.contains(spelling), "{spelling:?}: {text}");
    }
    // A target of the wrong JSON type is refused too, not read as the default.
    for wrong in ["null", "1", "true", "[\"metal_msl\"]"] {
        let c = compile_plain(&with_extra(&format!(r#","target":{wrong}"#)));
        assert_eq!(c.status, RS_SHADER_ERROR, "target {wrong}");
    }
    // An omitted target and the Metal one give identical documents.
    let omitted = ok(&textured());
    let explicit = ok(&request_with(VERTEX, FRAGMENT, false, r#","target":"metal_msl","textures":[{"slot":0,"enabled":true,"format":"rgba8"}]"#));
    for i in 0..2 {
        assert_eq!(omitted.msl(i), explicit.msl(i));
        assert_eq!(omitted.stage_doc(i), explicit.stage_doc(i));
    }
    assert_eq!(omitted.metadata(), explicit.metadata());
    assert_eq!(omitted.reflection(), explicit.reflection());
    assert_eq!(omitted.diagnostics(), explicit.diagnostics());
    assert_eq!(omitted.key(), explicit.key());
}

#[test]
fn the_stage_target_is_one_for_a_valid_stage_and_never_zero() {
    let c = ok(&textured());
    unsafe {
        for i in 0..2usize {
            assert_eq!(rs_shader_program_stage_target(c.handle, i), 1);
        }
        for bad in [2usize, 7, usize::MAX] {
            assert_eq!(rs_shader_program_stage_target(c.handle, bad), -1);
        }
        assert_eq!(rs_shader_program_stage_target(ptr::null(), 0), -1);
    }
    // The old Vulkan code is retired for good: the header says so, next to the Metal value.
    let header = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/include/rs_shader.h")).unwrap();
    assert!(header.contains("RS_SHADER_TARGET_METAL 1"));
    assert!(header.contains("0 is retired"), "the header must say that target 0 is retired");
    assert!(!header.contains("RS_SHADER_TARGET_VULKAN"), "no name may exist for the retired target");
}

#[test]
fn the_identity_is_an_opaque_string_that_is_not_the_retired_libraries() {
    let identity = text_of(rs_shader_cache_identity());
    // `<revision>:<text>`, compared only for equality; it names Metal, never the retired target.
    let (revision, rest) = identity.split_once(':').expect("a revision, a colon, then text");
    assert!(!revision.is_empty() && revision.bytes().all(|b| b.is_ascii_digit()), "{identity}");
    assert!(!identity.contains("spv") && !identity.contains("spirv") && !identity.contains("vulkan"), "{identity}");
    assert_ne!(revision, "17", "the retired library's revision is never reused: {identity}");
    assert!(rest.contains("msl"), "{identity}");
    // Stable across calls and threads.
    let again = thread::spawn(|| text_of(rs_shader_cache_identity())).join().unwrap();
    assert_eq!(identity, again);
}

#[test]
fn a_success_diagnostics_document_has_one_codegen_entry_per_stage_with_a_valid_span() {
    let c = ok(&textured());
    let diagnostics = c.diagnostics();
    let entries = items(&diagnostics);
    assert_eq!(entries.len(), 2, "{diagnostics:?}");
    for (entry, stage) in entries.iter().zip(["Vertex", "Fragment"]) {
        assert_eq!(member(entry, "pass"), &Value::String("Codegen".into()));
        assert_eq!(member(entry, "stage"), &Value::String(stage.into()));
        let span = member(entry, "span");
        assert!(matches!(span, Value::Object(_)), "{entry:?}");
        let number = |key: &str| match member(span, key) {
            Value::Number(n) => n.as_u64().expect("a plain integer"),
            other => panic!("span {key} is {other:?}"),
        };
        // The start is not after the end; that the span lies inside the text of the pass is checked
        // where the text is known (the pipeline tests).
        assert!(number("start") <= number("end"), "{span:?}");
    }
}

#[cfg(feature = "observer-uniform-layout")]
#[test]
fn existing_reflection_accessor_owns_original_stage_layouts_with_no_new_abi_entry() {
    let c = ok(&textured());
    let reflection = c.reflection();
    let diagnostic = member(&reflection, "observer_uniform_layout");
    assert_eq!(string_of(member(diagnostic, "origin")), "original-translated-naga-module");
    let Value::Number(version) = member(diagnostic, "schema_version") else { panic!() };
    assert_eq!(version.as_u64(), Some(1));
    let stages = items(member(diagnostic, "stages"));
    assert_eq!(stages.len(), 2);
    for (index, stage) in stages.iter().enumerate() {
        assert_eq!(string_of(member(stage, "stage")), if index == 0 { "vertex" } else { "fragment" });
        assert_eq!(member(stage, "complete"), &Value::Bool(true));
        assert_eq!(string_of(member(stage, "msl_entry_point")), string_of(member(&c.stage_doc(index), "entry_point")));
        assert_eq!(string_of(member(member(stage, "blocks"), "status")), "available");
    }
    let vertex_blocks = items(member(member(&stages[0], "blocks"), "value"));
    let fragment_blocks = items(member(member(&stages[1], "blocks"), "value"));
    assert_eq!(vertex_blocks.len(), 1);
    assert!(fragment_blocks.is_empty(), "vertex-only uniform use must not be merged into the fragment diagnostic");
    let layout = member(member(&vertex_blocks[0], "layout"), "value");
    let members = items(member(layout, "members"));
    let matrix = members.iter().find(|m| string_of(member(m, "name")) == "g_ModelViewProjectionMatrix").unwrap();
    let physical = member(member(matrix, "layout"), "value");
    let shape = member(member(physical, "type"), "element_shape");
    assert_eq!(string_of(member(shape, "kind")), "matrix");
    let Value::Number(stride) = member(shape, "column_stride") else { panic!() };
    assert_eq!(stride.as_u64(), Some(16));
    assert!(text_of(rs_shader_cache_identity()).ends_with("-observer-uniform-layout-v1"));
}
