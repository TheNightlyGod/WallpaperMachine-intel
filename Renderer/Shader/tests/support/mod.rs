// This project's own code, written from the clean-room specification (no upstream code consulted).
//
// Shared by the translator regression tests (declarator lists, integer `clamp`/`min`/`max`, scalar
// swizzles, run-time `#if` conditions). Three ways of looking at a translation:
//
// * `program` compiles a vertex and fragment pair through the whole pipeline (legalized GLSL, Metal
//   text, reflection, metadata, diagnostics);
// * `kernel` converts a compute kernel written in the dialect, reads it with naga's GLSL front end,
//   validates it and writes Metal, so the types naga gives to locals and calls can be asserted
//   without a GPU;
// * `gpu_run` evaluates such a kernel with one thread on the GPU and returns its buffer. It is
//   opt-in like `tests/gpu_probe.rs` (WM_SHADER_GPU_PROBES=1, needs swiftc and a Metal device; no
//   window, no display) and returns `None`, after printing why, when it cannot run.
#![allow(dead_code)]

use std::path::PathBuf;
use std::process::Command;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicUsize, Ordering};

use naga::back::msl;
use naga::front::glsl::{Frontend, Options};
use naga::valid::{Capabilities, ModuleInfo, ValidationFlags, Validator};
use naga::{Handle, MathFunction, ScalarKind, TypeInner};
use wm_shader::dialect::convert_stage;
use wm_shader::pipeline::{CompiledProgram, compile};
use wm_shader::source::NoIncludes;
use wm_shader::{ShaderError, ShaderRequest, Stage, StageKind};

/// A plain vertex stage for programs whose fragment stage is under test.
pub const VERTEX: &str = "attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 v_TexCoord;
void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }";

/// Compiles `fragment` with [`VERTEX`] through the pipeline.
pub fn program(fragment: &str) -> Result<CompiledProgram, ShaderError> {
    let request = ShaderRequest {
        shader_name: "translator/probe".into(),
        stages: vec![
            Stage { kind: StageKind::Vertex, source: VERTEX.into() },
            Stage { kind: StageKind::Fragment, source: fragment.into() },
        ],
        ..ShaderRequest::default()
    }
    .validate()
    .expect("a valid request");
    compile(&request, &NoIncludes)
}

/// [`program`], which must succeed.
pub fn program_ok(fragment: &str) -> CompiledProgram {
    program(fragment).unwrap_or_else(|e| panic!("the program does not compile:\n{e}\n{fragment}"))
}

/// The naga IR of the fragment stage the pipeline compiled (read again from its legalized GLSL).
pub fn fragment_ir(program: &CompiledProgram) -> Ir {
    let glsl = &program.stage(StageKind::Fragment).expect("a fragment stage").glsl;
    Ir::read(glsl, naga::ShaderStage::Fragment)
}

/// The shape of a naga type, as far as these tests look at it.
#[derive(Clone, Debug, PartialEq)]
pub enum Shape {
    Scalar(ScalarKind),
    Vector(ScalarKind, u8),
    Array(Box<Shape>, Option<u32>),
    Other(String),
}

pub const FLOAT: Shape = Shape::Scalar(ScalarKind::Float);
pub const INT: Shape = Shape::Scalar(ScalarKind::Sint);
pub const UINT: Shape = Shape::Scalar(ScalarKind::Uint);

pub fn vector(kind: ScalarKind, width: u8) -> Shape {
    Shape::Vector(kind, width)
}

pub fn array(element: Shape, len: u32) -> Shape {
    Shape::Array(Box::new(element), Some(len))
}

/// A naga module that passed validation, with what validation found out about it.
pub struct Ir {
    pub module: naga::Module,
    pub info: ModuleInfo,
    pub text: String,
}

impl Ir {
    /// Reads GLSL with naga's front end and validates it; panics with naga's words on failure.
    pub fn read(glsl: &str, stage: naga::ShaderStage) -> Ir {
        let module = Frontend::default()
            .parse(&Options::from(stage), glsl)
            .unwrap_or_else(|e| panic!("naga cannot read the stage: {:?}\n{glsl}", e.errors.iter().map(|x| x.kind.to_string()).collect::<Vec<_>>()));
        let info = Validator::new(ValidationFlags::all(), Capabilities::all())
            .validate(&module)
            .unwrap_or_else(|e| panic!("naga refuses the stage: {}\n{glsl}", e.as_inner()));
        Ir { module, info, text: glsl.to_string() }
    }

    fn shape_of_inner(&self, inner: &TypeInner) -> Shape {
        match inner {
            TypeInner::Scalar(s) => Shape::Scalar(s.kind),
            TypeInner::Vector { size, scalar } => Shape::Vector(scalar.kind, *size as u8),
            TypeInner::Array { base, size, .. } => {
                let len = match size {
                    naga::ArraySize::Constant(n) => Some(n.get()),
                    _ => None,
                };
                Shape::Array(Box::new(self.shape_of(*base)), len)
            }
            other => Shape::Other(format!("{other:?}")),
        }
    }

    pub fn shape_of(&self, ty: Handle<naga::Type>) -> Shape {
        self.shape_of_inner(&self.module.types[ty].inner)
    }

    /// A function by its GLSL name. naga's GLSL front end keeps the author's `main` as an ordinary
    /// function that its entry point calls.
    fn function(&self, name: &str) -> (&naga::Function, &naga::valid::FunctionInfo) {
        let (handle, f) = self
            .module
            .functions
            .iter()
            .find(|(_, f)| f.name.as_deref() == Some(name))
            .unwrap_or_else(|| panic!("no function `{name}` in\n{}", self.text));
        (f, &self.info[handle])
    }

    /// The type of the local variable `name` of function `func` (the first one of that name).
    pub fn local_in(&self, func: &str, name: &str) -> Shape {
        let (f, _) = self.function(func);
        let var = f
            .local_variables
            .iter()
            .map(|(_, v)| v)
            .find(|v| v.name.as_deref() == Some(name))
            .unwrap_or_else(|| panic!("no local `{name}` in `{func}` of\n{}", self.text));
        self.shape_of(var.ty)
    }

    /// The type of the local variable `name` of `main`.
    pub fn local(&self, name: &str) -> Shape {
        self.local_in("main", name)
    }

    /// The types of every local of `main` called `name`, in declaration order (shadowing locals).
    pub fn locals(&self, name: &str) -> Vec<Shape> {
        let (f, _) = self.function("main");
        f.local_variables.iter().filter(|(_, v)| v.name.as_deref() == Some(name)).map(|(_, v)| self.shape_of(v.ty)).collect()
    }

    /// The type of the module-scope variable or constant `name`.
    pub fn global(&self, name: &str) -> Shape {
        if let Some((_, g)) = self.module.global_variables.iter().find(|(_, g)| g.name.as_deref() == Some(name)) {
            return self.shape_of(g.ty);
        }
        if let Some((_, c)) = self.module.constants.iter().find(|(_, c)| c.name.as_deref() == Some(name)) {
            return self.shape_of(c.ty);
        }
        panic!("no global `{name}` in\n{}", self.text)
    }

    /// The result types of the calls of the math function `fun` in function `func`, in order.
    pub fn math_results_in(&self, func: &str, fun: MathFunction) -> Vec<Shape> {
        let (f, info) = self.function(func);
        f.expressions
            .iter()
            .filter(|(_, e)| matches!(e, naga::Expression::Math { fun: g, .. } if *g == fun))
            .map(|(h, _)| self.shape_of_inner(info[h].ty.inner_with(&self.module.types)))
            .collect()
    }

    pub fn math_results(&self, fun: MathFunction) -> Vec<Shape> {
        self.math_results_in("main", fun)
    }

    /// For each call of the math function `fun` in `main`, in order: whether its first argument is
    /// a texture sample itself (rather than something computed from one).
    pub fn math_first_argument_is_a_sample(&self, fun: MathFunction) -> Vec<bool> {
        let (f, _) = self.function("main");
        f.expressions
            .iter()
            .filter_map(|(_, e)| match e {
                naga::Expression::Math { fun: g, arg, .. } if *g == fun => {
                    Some(matches!(f.expressions[*arg], naga::Expression::ImageSample { .. }))
                }
                _ => None,
            })
            .collect()
    }

    /// The type of an expression of `main`.
    pub fn expression_shape(&self, handle: Handle<naga::Expression>) -> Shape {
        let (_, info) = self.function("main");
        self.shape_of_inner(info[handle].ty.inner_with(&self.module.types))
    }
}

// ----- compute kernels written in the dialect -----

/// The head of every kernel: one thread and a read-write buffer of 64 floats called `data`.
pub const KERNEL_HEAD: &str = "layout(local_size_x = 1) in;\nlayout(std430, set = 0, binding = 0) buffer Out { float data[64]; };\n";

/// A kernel converted from the dialect, accepted by naga and written as Metal.
pub struct Kernel {
    pub ir: Ir,
    pub msl: String,
    pub entry: String,
}

/// Converts a kernel (as the fragment stage converter would), reads and validates it with naga and
/// writes Metal. Panics, naming the step, when any of that fails.
pub fn kernel(src: &str) -> Kernel {
    let converted = convert_stage(StageKind::Fragment, src).unwrap_or_else(|d| panic!("conversion failed: {d:?}\n{src}"));
    let ir = Ir::read(&converted.text, naga::ShaderStage::Compute);
    let mut options = msl::Options { lang_version: (2, 0), fake_missing_bindings: false, ..Default::default() };
    let mut resources = msl::EntryPointResources::default();
    resources.resources.insert(
        naga::ResourceBinding { group: 0, binding: 0 },
        msl::BindTarget { buffer: Some(0), mutable: true, ..Default::default() },
    );
    options.per_entry_point_map.insert("main".to_string(), resources);
    let (msl, _) = msl::write_string(&ir.module, &ir.info, &options, &msl::PipelineOptions::default())
        .unwrap_or_else(|e| panic!("the Metal writer failed: {e}\n{}", converted.text));
    let entry = msl
        .lines()
        .find_map(|l| l.strip_prefix("kernel void ").and_then(|r| r.split('(').next()))
        .unwrap_or_else(|| panic!("no kernel in\n{msl}"))
        .to_string();
    Kernel { ir, msl, entry }
}

fn scratch_dir() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("translator_probe");
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// The kernel runner (`tests/probes/run_kernel.swift`), built once per test binary.
fn runner() -> Option<&'static PathBuf> {
    static RUNNER: OnceLock<Option<PathBuf>> = OnceLock::new();
    RUNNER
        .get_or_init(|| {
            if std::env::var_os("WM_SHADER_GPU_PROBES").is_none() {
                eprintln!("skipped: set WM_SHADER_GPU_PROBES=1 to evaluate the kernels on the GPU (needs swiftc and a Metal device)");
                return None;
            }
            let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/probes/run_kernel.swift");
            // One runner per test binary, so binaries that share this module never race on it.
            let binary = scratch_dir().join(format!("run_kernel_{}", env!("CARGO_CRATE_NAME")));
            match Command::new("swiftc").arg("-O").arg(&source).arg("-o").arg(&binary).output() {
                Ok(o) if o.status.success() => Some(binary),
                Ok(o) => {
                    eprintln!("skipped: swiftc failed: {}", String::from_utf8_lossy(&o.stderr));
                    None
                }
                Err(e) => {
                    eprintln!("skipped: swiftc is not available: {e}");
                    None
                }
            }
        })
        .as_ref()
}

/// Runs the kernel with one thread over `data` (the first values set from `inputs`, the rest 0)
/// and returns the 64 floats afterwards. `None` when the GPU probes are off or cannot run here.
pub fn gpu_run(kernel: &Kernel, inputs: &[f32]) -> Option<Vec<f32>> {
    let runner = runner()?;
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let file = scratch_dir().join(format!("kernel_{}_{}.metal", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
    std::fs::write(&file, &kernel.msl).unwrap();
    let mut cmd = Command::new(runner);
    cmd.arg(&file).arg(&kernel.entry).arg("64");
    for v in inputs {
        cmd.arg(v.to_string());
    }
    let run = cmd.output().expect("the kernel runner starts");
    let _ = std::fs::remove_file(&file);
    let out = String::from_utf8_lossy(&run.stdout).to_string();
    if out.contains("no-device") {
        eprintln!("skipped: no Metal device");
        return None;
    }
    assert!(run.status.success(), "the kernel runner failed: {out}{}\n{}", String::from_utf8_lossy(&run.stderr), kernel.msl);
    Some(out.lines().map(|l| l.trim().parse().expect("one float per line")).collect())
}

pub fn near(a: f32, b: f32) -> bool {
    (a - b).abs() <= 1e-4 * (1.0 + b.abs())
}

/// Asserts `out[i] == want` (within float tolerance) for every pair.
pub fn assert_values(out: &[f32], want: &[(usize, f32)]) {
    for &(i, w) in want {
        assert!(near(out[i], w), "data[{i}] = {}, wanted {w}", out[i]);
    }
}
