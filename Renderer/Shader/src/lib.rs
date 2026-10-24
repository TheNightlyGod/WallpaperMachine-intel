// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Wallpaper Engine shader text in, Metal Shading Language and reflection out.
//!
//! This crate is the shader layer of the renderer. Its public model (requests,
//! responses, reflection, diagnostics, errors, cache identity) does not depend
//! on the compiler; the compiler pipeline plugs into it.
#![deny(warnings)]
// Unsafe code lives only in the C ABI module, and only when that feature is on.
#![deny(unsafe_code)]

pub mod annotation;
pub mod backend;
pub mod binding;
pub mod cache_key;
pub mod diagnostic;
pub mod dialect;
pub mod error;
#[cfg(feature = "ffi")]
#[allow(unsafe_code)]
pub mod ffi;
pub mod facts;
pub mod identity;
pub mod include;
pub mod items;
pub mod json;
pub mod legalize;
pub mod lexer;
pub mod metadata;
pub mod names;
mod nagair;
#[cfg(feature = "observer-uniform-layout")]
pub mod observer_uniform_layout;
pub mod pipeline;
pub mod prepare;
pub mod preprocess;
pub mod reflect;
pub mod reflection;
pub mod request;
pub mod request_json;
pub mod response;
pub mod source;
mod sha256;
mod text;
pub mod uniforms;

pub use error::ShaderError;
pub use request::*;
pub use request_json::{parse_request, parse_request_bytes};
