// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Behaviour tests of the backend, written from the behaviour list of spec part D (section 8,
//! items 18 to 26 and 37). They hand the backend legalized GLSL written out in full, so what
//! they check is the backend's own work and not the legalizer's.

pub(crate) mod support;

mod builtins;
mod conventions;
mod failures;
mod inverse;
mod layout;
mod literals;
mod map;
mod quad;
mod text;
