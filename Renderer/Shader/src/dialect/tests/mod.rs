// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Behaviour tests of the dialect front end, written from the behaviour list of spec part C1
//! (section 8). Each test converts a small stage and, where meaning matters, compiles the
//! result through naga to Metal and inspects what naga built.

pub mod support;

mod boundary;
mod calls;
mod conversions;
pub(crate) mod corpus;
mod declarations;
mod edge_cases;
mod operators;
mod structure;
mod vocabulary;
