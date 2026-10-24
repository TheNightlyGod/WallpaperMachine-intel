// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Behaviour tests of the interface and resource part, written from the behaviour list of
//! spec C2 (section 8). Each test legalizes small stages and, where meaning matters, compiles
//! the result through naga to Metal and inspects what naga built.

pub(crate) mod support;

mod composition;
mod control_flow;
mod corpus;
mod interface;
mod layout;
mod renames;
mod textures;
