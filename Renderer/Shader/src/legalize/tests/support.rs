// This project's own code, written from the clean-room specification (no upstream code consulted).
#![allow(dead_code)]
//
//! Helpers shared by the legalisation tests.

use crate::dialect::tests::support::{Compiled, compile_glsl};
use crate::legalize::{LegalProgram, LegalizeError, ProgramInput, legalize, legalize_stage};
use crate::request::StageKind;

pub fn program(vertex: &str, fragment: &str) -> LegalProgram {
    match legalize(&ProgramInput::program(vertex, fragment)) {
        Ok(p) => p,
        Err(e) => panic!("legalization failed: {e}\n--- vertex ---\n{vertex}\n--- fragment ---\n{fragment}"),
    }
}

pub fn program_err(vertex: &str, fragment: &str) -> LegalizeError {
    match legalize(&ProgramInput::program(vertex, fragment)) {
        Ok(p) => panic!("legalization should have failed, got:\n{}\n{}", p.vertex.unwrap().text, p.fragment.unwrap().text),
        Err(e) => e,
    }
}

pub fn planes(vertex: &str, fragment: &str, slots: &[u8]) -> Result<LegalProgram, LegalizeError> {
    legalize(&ProgramInput::program(vertex, fragment).with_planes(slots))
}

/// The legalized text of a stage alone (R31, R41).
pub fn stage(kind: StageKind, src: &str) -> String {
    match legalize_stage(kind, src) {
        Ok((s, _)) => s.text,
        Err(e) => panic!("legalization failed: {e}\n--- source ---\n{src}"),
    }
}

pub fn stage_err(kind: StageKind, src: &str) -> LegalizeError {
    match legalize_stage(kind, src) {
        Ok((s, _)) => panic!("legalization should have failed, got:\n{}", s.text),
        Err(e) => e,
    }
}

pub fn frag(src: &str) -> String {
    stage(StageKind::Fragment, src)
}

pub fn vert(src: &str) -> String {
    stage(StageKind::Vertex, src)
}

/// Both stages of a program compiled through naga to Metal.
pub struct BothCompiled {
    pub vertex: Compiled,
    pub fragment: Compiled,
    pub program: LegalProgram,
}

pub fn compile_program(vertex: &str, fragment: &str) -> BothCompiled {
    let p = program(vertex, fragment);
    let v = p.vertex.as_ref().unwrap();
    let f = p.fragment.as_ref().unwrap();
    let vc = compile_glsl(StageKind::Vertex, &v.text).unwrap_or_else(|e| panic!("naga rejected the vertex stage: {e}"));
    let fc = compile_glsl(StageKind::Fragment, &f.text).unwrap_or_else(|e| panic!("naga rejected the fragment stage: {e}"));
    BothCompiled { vertex: vc, fragment: fc, program: p }
}

pub fn compile_one(kind: StageKind, src: &str) -> Compiled {
    let text = stage(kind, src);
    compile_glsl(kind, &text).unwrap_or_else(|e| panic!("naga rejected the stage: {e}\n--- source ---\n{src}"))
}

pub fn compile_frag(src: &str) -> Compiled {
    compile_one(StageKind::Fragment, src)
}

pub fn compile_vert(src: &str) -> Compiled {
    compile_one(StageKind::Vertex, src)
}

/// True when `word` occurs in `text` as a whole identifier.
pub fn has_word(text: &str, word: &str) -> bool {
    crate::dialect::tests::support::has_word(text, word)
}

pub fn count(hay: &str, needle: &str) -> usize {
    hay.matches(needle).count()
}
