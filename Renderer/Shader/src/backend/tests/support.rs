// This project's own code, written from the clean-room specification (no upstream code consulted).
#![allow(dead_code)]
//
//! Helpers shared by the backend tests.

use naga::{
    AddressSpace, Binding as NagaBinding, EntryPoint, Function, FunctionResult, GlobalVariable, Handle,
    MemoryDecorations, Module, ResourceBinding, ShaderStage, Span, Type, TypeInner,
};

use crate::backend::{CompiledStage, compile_glsl, translate_module};
use crate::binding::{Binding, SlotKind};
use crate::error::ShaderError;
use crate::request::StageKind;

/// A fragment stage that writes one colour and nothing else.
pub const FRAGMENT_HEAD: &str = "#version 450\nprecision highp float;\n";

pub fn compile(kind: StageKind, glsl: &str) -> CompiledStage {
    match compile_glsl(kind, glsl) {
        Ok(c) => c,
        Err(e) => panic!("the backend failed:\n{e}\n--- source ---\n{glsl}"),
    }
}

pub fn fragment(glsl: &str) -> CompiledStage {
    compile(StageKind::Fragment, glsl)
}

pub fn vertex(glsl: &str) -> CompiledStage {
    compile(StageKind::Vertex, glsl)
}

pub fn fail(kind: StageKind, glsl: &str) -> ShaderError {
    match compile_glsl(kind, glsl) {
        Ok(c) => panic!("the backend should have failed, got:\n{}", c.payload.msl_source),
        Err(e) => e,
    }
}

pub fn msl(c: &CompiledStage) -> &str {
    &c.payload.msl_source
}

pub fn binding<'a>(c: &'a CompiledStage, name: &str) -> &'a Binding {
    c.payload.bindings.iter().find(|b| b.name == name).unwrap_or_else(|| {
        panic!("no binding record named {name}: {:?}", c.payload.bindings.iter().map(|b| &b.name).collect::<Vec<_>>())
    })
}

pub fn slot_of(c: &CompiledStage, name: &str) -> (SlotKind, u32, u32) {
    let b = binding(c, name);
    (b.slot_kind, b.binding, b.slot)
}

/// A module under construction, built with naga's own API.
pub struct Ir {
    pub module: Module,
}

impl Ir {
    pub fn new() -> Ir {
        Ir { module: Module::default() }
    }

    pub fn ty(&mut self, name: Option<&str>, inner: TypeInner) -> Handle<Type> {
        self.module.types.insert(Type { name: name.map(String::from), inner }, Span::UNDEFINED)
    }

    pub fn global(
        &mut self,
        name: Option<&str>,
        space: AddressSpace,
        binding: Option<(u32, u32)>,
        ty: Handle<Type>,
    ) -> Handle<GlobalVariable> {
        self.module.global_variables.append(
            GlobalVariable {
                name: name.map(String::from),
                space,
                binding: binding.map(|(group, binding)| ResourceBinding { group, binding }),
                ty,
                init: None,
                memory_decorations: MemoryDecorations::default(),
            },
            Span::UNDEFINED,
        )
    }

    /// An entry point with an empty body (it never validates when it must return a value).
    pub fn entry(&mut self, stage: ShaderStage) {
        let function = Function { name: Some("main".into()), ..Function::default() };
        self.module.entry_points.push(EntryPoint {
            name: "main".into(),
            stage,
            early_depth_test: None,
            workgroup_size: [0; 3],
            workgroup_size_overrides: None,
            function,
            mesh_info: None,
            task_payload: None,
            incoming_ray_payload: None,
        });
    }

    pub fn translate(self, kind: StageKind) -> Result<CompiledStage, ShaderError> {
        translate_module(kind, self.module, "")
    }
}

pub fn sampler_type(ir: &mut Ir) -> Handle<Type> {
    ir.ty(None, TypeInner::Sampler { comparison: false })
}

pub fn image_2d(ir: &mut Ir) -> Handle<Type> {
    ir.ty(
        None,
        TypeInner::Image {
            dim: naga::ImageDimension::D2,
            arrayed: false,
            class: naga::ImageClass::Sampled { kind: naga::ScalarKind::Float, multi: false },
        },
    )
}

pub fn f32_type(ir: &mut Ir) -> Handle<Type> {
    ir.ty(None, TypeInner::Scalar(naga::Scalar::F32))
}

pub fn result_position(ir: &mut Ir) -> FunctionResult {
    let vec4 = ir.ty(None, TypeInner::Vector { size: naga::VectorSize::Quad, scalar: naga::Scalar::F32 });
    FunctionResult { ty: vec4, binding: Some(NagaBinding::BuiltIn(naga::BuiltIn::Position { invariant: false })) }
}
