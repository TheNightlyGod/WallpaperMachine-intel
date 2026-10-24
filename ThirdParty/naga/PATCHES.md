# Patches against naga 29.0.3

This directory is the published `naga` 29.0.3 crate (gfx-rs/wgpu, `naga/` at
`4cbe6232b2d7c289b6e1a38416a6ae1461a22e81`), licensed `MIT OR Apache-2.0` and used by this
project under the MIT license. `LICENSE.MIT` and `LICENSE.APACHE` are the crate's own.
`Cargo.lock`, `.cargo-ok`, `.cargo/` and the git metadata files of the published tarball are not
vendored. `Cargo.toml.orig` and `.cargo_vcs_info.json` are kept as published and describe the
unpatched crate; cargo reads only `Cargo.toml`.

`Renderer/Cargo.toml` points the workspace at this copy as a path dependency (`[workspace.dependencies]`).

## Why

Upstream makes `codespan-reporting` (Apache-2.0) a non-optional dependency, only to format
diagnostics as text. The renderer renders its own diagnostics (`crates/shader/src/error/report.rs`)
from naga's public span and label API, so the dependency is optional here and the shader crate
does not enable it. The only change is that the text helpers sit behind a new feature.

## What differs

Everything else, including the public API of every feature combination that already worked, is
unchanged.

1. `Cargo.toml`
   - `codespan-reporting` is `optional = true`.
   - New feature `codespan = ["dep:codespan-reporting"]`.
   - `stderr`, `termcolor`, `spv-in` and `wgsl-in` each also enable `codespan` (upstream they used
     `codespan-reporting` unconditionally), so their behavior is unchanged.
   - The default feature set is still empty. Without `codespan`, `glsl-in`, validation and the
     writers (`spv-out`, `msl-out`, ...) build with no `codespan-reporting` and no `termcolor`.
2. `src/error.rs`
   - `DiagnosticBuffer`, `emit_to_writer`, `ErrorWrite`, `replace_control_chars` (and its test) are
     `cfg(feature = "codespan")`.
   - The `Display` impls of `ShaderError<glsl::ParseErrors>` and
     `ShaderError<WithSpan<ValidationError>>` format through codespan when `codespan` is on (as
     upstream) and fall back to the plain error messages (no source excerpt) otherwise.
3. `src/span.rs`: `WithSpan::diagnostic`, `emit_to_string` and `emit_to_string_with_path` are
   `cfg(feature = "codespan")` (`emit_to_stderr*` already needed `stderr`, which implies it).
4. `src/front/glsl/error.rs`: the codespan imports, `ParseErrors::emit_to_string`,
   `emit_to_string_with_path` and `make_diagnostic` are `cfg(feature = "codespan")`.

`src/front/wgsl/` and `src/front/spv/` are untouched: both front ends need `codespan`, which their
features now enable.

Callers that used `emit_to_string*` without naming the feature must enable `codespan`. The project's
shader crate formats the information itself: `WithSpan::spans`, `WithSpan::as_inner`, the error
`source()` chain, and for GLSL `Error::kind`, `Error::meta` and `Span::to_range`.

## Re-applying on an upgrade

1. Copy the new published crate over this directory, keeping this file.
2. Redo the four changes above; each is a `cfg` on the items listed, plus the manifest lines.
3. Check that every feature combination builds: none, `glsl-in`, `codespan`, `stderr`, and the
   renderer's `glsl-in,spv-out,msl-out`; and that
   `cargo tree -e normal,no-proc-macro --target aarch64-apple-darwin` for the workspace lists no
   `codespan-reporting`.
4. Update `ThirdParty/provenance.json` and `LICENSING.md`. Drop this patch if upstream makes the
   dependency optional.
