# Shader crate notes

This project's own code, written from the clean-room specification (no upstream
code consulted). The spec is `specs/shader/` of the own-code plan; this file
records what the spec leaves open and the choice made, plus dependency and
toolchain facts. Keep it current as later steps land.

## Layout

`Renderer/Cargo.toml` is the workspace (resolver 2, edition 2024, GPL-3.0-only). `Renderer/Shader` is the crate `wm-shader`
(`rlib` + `staticlib`; the non-default `ffi` feature adds the C ABI of Step 6, declared by
`include/rs_shader.h`).

Modules by spec part. Step 1: `request`, `request_json`, `json`, `names`,
`include` (path rules), `response`, `reflection`, `uniforms`, `binding`,
`diagnostic`, `error`, `cache_key`, `identity`. Step 2 (part B of the spec):
`source` (include providers, `CachingSource`), `preprocess` (`expr`,
`lighting`), `lexer`, `facts` (R43 to R49), `items` (R50 to R55),
`annotation` (JSON reader, R8 text conversion), `metadata` (R62 to R71),
`prepare` (the combo protocol, P1 to P5). `tests/corpus.rs` runs the front end
over the shipped shaders (and over workshop shaders unpacked under
`artifacts/p5/workshop-shaders/<id>/shaders/`, which it skips when absent);
`tests/robustness.rs` feeds it garbled and hostile text.

Step 3 (part C1 of the spec) is the module `dialect`: `expand` (macro expansion),
`parse` (tokens to the tree of `ast`), `ty` and `builtins` (the type model and what is
known about calls by name), `convert` (the typed rewrite: `expr`, `coerce`, `call`, `stmt`,
`items`, `special`, `helpers`), `print` (tree to GLSL text) and `usage` (the use facts of
R7). `dialect::convert_stage` is the entry point; its result carries the text *and* the
rewritten tree, so the interface and resource parts can work on the tree.
Step 4 (part C2 of the spec) is the module `legalize`: `collect` (declaration planning, R9 to R13),
`block` (the uniform block, R14 to R23 and R83, R87), `bindings` (R24 to R31), `interface` (locations,
reconciliation and synthesized outputs, R32 to R41, R82, R84), `rewrite` (sampling calls, plane
sampling, widened reads, the colour output; R42 to R44, R47, R49, R21, R78), `planes` (R45 to R48)
and `stage` (assembly, R6 and R8). `legalize::legalize` takes both stages of a program (or one
stage, which gets the standalone numbering of R31 and R41) and returns the GLSL text of each stage
plus `ProgramLayout`, the facts reflection needs (block members and binding, textures with their
two bindings, planes, vertex inputs under their author names, varyings, kept samplers).
`src/legalize/tests/` holds the tests of section 8 and the corpus sweeps; `tests/gpu_probe.rs` gained
the NV12 conversion probe and the float remainder probe. (`binding::assign_metal_slots`, the dense
sampler ranks of C2 R88, is gone: part D R46 ranks every namespace of a stage, see Step 5.)

Step 5 (part D of the spec) is three modules and a pipeline. `backend` reads one legalized stage with
naga's GLSL front end, builds the Metal binding map, validates, and runs the Metal writer
(`StageCompiler`, `NagaBackend`, `compile_glsl`, `translate_module`). `reflect` describes the module
that was translated (`StageReflector`, `NagaReflector`, `reflect_module`, `reflect_untranslated`);
`reflect::coverage` proves the two coverage facts of note 140 and the fragment colour of note 142,
and `reflect::reads` the read uniforms of note 141.
`nagair` holds what both need to know about the globals of a naga module. `pipeline` drives a request
through `prepare`, `legalize`, the compiler and the reflector, merges the stage reflections, and
computes the key (`Pipeline`, `compile`, `CompiledProgram`). The compiler and the reflector are the two
replaceable steps of R6: the pipeline tests replace both. `ShaderError::category()` gives the classes
of section 5 (`ErrorCategory`).

`tests/dialect_robustness.rs` is the hostile-input test of this part (run on a 2 MiB stack),
`tests/gpu_probe.rs` the opt-in Metal probes (a Swift runner dispatches one compute thread; no window,
no display): the smoothstep and `fmod` probe, and kernels written in the dialect that are converted,
written as Metal through naga and evaluated, whose values are compared with HLSL's (author-defined
functions, signed and unsigned bit operations, remainder, truncation, bool and number conversions, `!`/`&&`, `mul` with `mat4x3`,
`CAST3X3`, array-parameter specialisation, moved global initializers, float subscripts and loop
bounds). Run them with `WM_SHADER_GPU_PROBES=1 cargo test -p wm-shader --test gpu_probe`; without the
variable they print why they did nothing.

Step 6 (part A of the spec, the boundary) is the module `ffi` (feature `ffi` only), the header
`include/rs_shader.h`, and `backend::depth`. `ffi` holds the thirteen exported functions, the handle
(`RsShaderProgram`, built once when the compile returns and then immutable), the per-thread last-error
buffer, the include provider over the callback (`CallbackSource: IncludeSource`) and the panic
containment. Tests: `src/ffi/tests.rs` (forced panic, hook silence, flag bookkeeping),
`tests/ffi_abi.rs` (the ABI through raw pointers, 34 tests) and `tests/c_abi.rs` (a C program built
from `tests/c/abi_smoke.c` against the header and `libwm_shader.a`, the header as C and C++, the
archive's exported symbols).

## Dependencies

- `naga` 29.0.3 by path (`../ThirdParty/naga` from `Renderer/`), features
  `glsl-in` and `msl-out` only (MIT OR Apache-2.0). It is the compiler the backend calls (front end,
  validator, Metal writer). `identity::NAGA_VERSION` is checked against the vendored manifest by a test.
- Nothing else. The request reader and the response writer use the crate's own
  small JSON module (`json.rs`; strict RFC 8259, depth limited to 128), cache
  keys use an own SHA-256 (`sha256.rs`, FIPS 180-4, test vectors), errors
  implement `Display`/`Error` by hand. No `thiserror`, no `serde`.

## Toolchain

`rust-toolchain.toml` pins a stable release with the Apple target, which rustup
installs and uses ([build prerequisites](../../docs/build.md#prerequisites)).
The crate uses no nightly feature and builds, tests and passes clippy
(`cargo clippy --all-targets`, warnings denied) on that release.

## Spec ambiguities and the choice made

1. **R12 "folded name".** The duplicate-combo text uses the ASCII *lower-case*
   spelling as the folded name and then names both original spellings:
   ``duplicate combo name `transformuv` (given as `TransformUV` and `TRANSFORMUV`)``.
2. **R11, several stage problems.** When more than one thing is wrong the text
   lists all of them joined by `; ` (for example "duplicate vertex stage;
   missing fragment stage"), so a reader looking for either wording finds it.
3. **Error wording classes (Q10).** Problems reading the document (bad JSON,
   wrong types, missing keys, unknown enum spellings, duplicate keys, a slot
   that does not fit a byte, an unknown target) start with
   "json request parse failed". Rule violations of R10 to R14 start with
   "invalid shader request". Non-UTF-8 input says "request is not valid UTF-8".
4. **Duplicate keys.** A *known* key given twice anywhere in the document is a
   parse error ("duplicate key"); `cache_policy` together with
   `cache_strategy` is reported the same way. Unknown keys may repeat, they are
   never read.
5. **Cache policy details.** `mode` is required inside the object. `scene_id`
   is read only for `enabled` (any string, including empty, is accepted) and is
   ignored for `disabled`.
6. **Property numbers.** Stored as `f64`; a JSON number that overflows to
   infinity is a parse error ("out of range"). A `none` property needs no inner
   `value`; the outer `value` object itself is required. Duplicate property names
   are not rejected (the spec does not say), and order is kept.
7. **Texture slot tokens.** Only plain non-negative integer tokens count as a
   slot: `1.0`, `1e1`, `-1` and strings are parse errors ("does not fit in a
   byte"), 256 and up likewise; 32 to 255 are range errors from validation.
8. **JSON BOM.** A byte order mark in the *request document* is rejected (it is
   not JSON). Handling a BOM in *shader source* (edge case 17) is the
   preprocessor's business.
9. **Cache key order and contents (Q8, Q12).** Combos are hashed in sorted
   (name, value) order and texture records in slot order, so reordering them in
   the request does not change the key. Properties keep request order (their
   input is unused today and order could matter to a future reader). Stage
   order is part of the key because output order follows it (R9). The raw source
   text is hashed in addition to the preprocessed text and translated GLSL:
   annotations live in comments the preprocessor drops, yet the metadata depends
   on them (R84 "shader source text").
10. **Digest.** SHA-256 truncated to 128 bits, 32 lower-case hex digits.
11. **Compiler identity.** `<revision>:naga-<naga version>-msl<language
    version>-<options>`, currently `2:naga-29.0.3-msl2.0-untransformed` (Step 5 changed the
    first spelling `wm1-naga-...` to the `<integer>:<text>` form D R37 asks for; it differs from
    the stored upstream identity). `cache_key.rs` carries an append-only golden
    table of program keys per identity (R88): a change to what a key covers
    fails the row of the current identity and forces a deliberate bump and a new row.
12. **R83 (target changes the key).** The target is hashed, but with a single
    accepted target no test can change it; the test belongs with the first
    additional target.
13. **Diagnostics.** The document keeps exactly the five keys of 2.6.4 (no
    severity). Pass names are `Preprocess`, `Parse`, `Legalize`, `Codegen`,
    `GlslParse`, `Validate`, `MslWrite`, `Binding`, `Reflection` (only `Codegen`
    is pinned by the spec; the rest name the steps R71 lists). Failure text
    layout: `error: <message>`, `  --> <origin>:<line>:<column>`, a numbered
    excerpt with one line of context each side (at most five lines of the span),
    carets under a single-line span, and a `= stage: ..., pass: ..., shader: ...`
    line. The origin is `generated/<stage>.glsl` for downstream failures,
    otherwise `<shader name>.vert|.frag`. Blocks of several diagnostics are
    separated by a blank line. Control characters in anything echoed
    (tabs become spaces, the rest `?`) are removed so no terminal escape can
    reach the text (R71); values echoed from a request are cut at 120 characters.
    A span that is outside the text (or inside a multi-byte character) is not
    clamped: the excerpt and the line/column are left out (R73).
14. **Shader name in failure text.** Included for source failures (2.4 allows
    it); request and include failures do not carry it.
15. **Uniform error wording.** `UniformError` text has no prefix so that it
    *begins with* the wording R46, R99 and R100 fix.
16. **Matrix and array sizes (Q17).** Block members report the true std140
    footprint: `mat2` 32, `mat3` 48, `matCxR` is C columns of 16 bytes; array
    strides are the element size rounded up to 16 (so `int[N]` and `ivec3[N]`
    have stride 16, `mat2[N]` 32, `mat3[N]` 48); `float`, `vec2` and `vec3`
    arrays are widened to `vec4` elements (element count 4, stride 16). An array
    count of 0 and a block over 4 GiB are errors. Whether the MSL struct the
    pipeline writes agrees with these offsets is the pipeline's obligation
    (checked when it exists).
17. **Reflection merge.** Vertex inputs are ordered by (location, name) and
    exact duplicates collapse; the R36 index limits are checked inside `merge`.
    Active texture slots are a `BTreeSet<u8>` shared by the metadata and
    reflection documents so they cannot differ in order or duplicates (R52).
18. **Include paths.** Validity is checked on the normalised text: empty, NUL,
    leading `/` (which covers `//` and a backslash UNC prefix), a drive prefix
    (an ASCII letter then `:`), or a `..` component.


## Step 2 choices (preprocessing, tokens, facts, items, metadata)

Preprocessor and includes:

19. **Block comments (Q3).** As R12 says, the preprocessor is not comment aware:
    a directive on its own line inside `/* ... */` is executed. Metadata is
    unaffected because the lexer drops block comments before annotations are
    looked for.
20. **Continued directives (Q2).** A directive line whose last physical line ends
    in `\` is joined with the next one before it is read. The joined body (a
    continuation replaced by one space) feeds `#if` and `#define`; the output of
    `#define` and unknown directives keeps the original line breaks and the
    backslashes, so the downstream compiler sees the continued definition.
    Diagnostics name the first physical line. Ordinary lines keep R31: only the
    backslash is dropped (blanks before it stay, blanks after it go).
21. **Directive bodies (R14).** A body that starts with `<` but has no `>`
    protects nothing. A quote preceded by a backslash never toggles quoting, in
    or out of a string.
22. **Order of checks.** For `#else` the structure errors (unmatched, duplicate)
    come before the trailing-token error; for `#endif` the trailing-token error
    comes first, so `#endif junk` fails even when it is stray.
23. **Unknown directives in the view.** In the metadata-preserving view an unknown
    directive is kept once, normalised, whether its region is active or not
    (Q1's double emission is dropped); an inactive `#undef` is kept normalised
    and not applied.
24. **Plain numbers (R25).** A fraction needs digits after the dot: `5.` is
    opaque, `.5` is opaque, `+3` is the integer 3. A macro whose text is empty
    after a combo with an empty value is opaque and false.
25. **Chains (R25a).** A link is a macro whose whole text is one other
    identifier. Sixteen links resolve, seventeen fail; a link to a name that is
    not defined, a cycle, and an end text that is neither a plain number nor an
    identifier all give the unsupported-expression error naming the cause.
26. **Combo values with line breaks (Q21).** CR and LF in a combo value become a
    space in the definition line and in the environment, so a value can never
    start a new directive.
27. **Bounds (R77, 6.4).** Include depth 64, 20,000 include expansions per stage,
    8 MiB of expanded text, `#if` expressions nested at most 200 deep. Cycle
    detection compares paths with empty and `.` components removed; the message
    prints the chain as written (long chains are shortened with `...`).
28. **Leading macro facts (R38).** Computed while writing: a define records its
    trimmed replacement; a bare define, a function-like define or an empty combo
    records the name without a value; `#undef` removes; the first line that is
    not a define or undef (a blank line, a comment, ordinary code, another
    directive, the lighting block) ends the region; a skipped branch or a
    dropped `#require` writes nothing and does not end it.
29. **LightingV1 (R33, R34).** `LIGHTING` counts as enabled for any non-integer
    text and for any integer other than zero, negative ones included (`-1`).
    Counts are digits with an optional `+`; everything else, a negative number
    included, is 0; digit strings too long for an integer count as 15. The block
    is fully unrolled with constant indices and writes its zero as
    `vec3(0.0, 0.0, 0.0)` so it needs no dialect macro. The subset macros
    (`LIGHTS_POINT_SHADOW`, `LIGHTS_SPOT_SHADOW`, `LIGHTS_SPOT_COOKIE`,
    `LIGHTS_SPOT_SHADOW_COOKIE`, `LIGHTS_DIRECTIONAL_SHADOW`) are read the same way and
    capped at 3; they place each light in Wallpaper Engine's partition of its array
    (spot `[shadow cookie][cookie][shadow][plain]`, point and directional
    `[shadow][plain]`, `sub_140169140`). Shadow subsets use the generated projection
    and shadow helpers when `LIGHTS_SHADOW_MAPPING` is on; otherwise their shadow
    factor is `1.0`. Cookie subsets project and sample `COOKIE_SAMPLER` even without
    shadows. Their sampled RGB replaces the ordinary cone factor. Revision 7 adds
    this cookie path; no cookie subset adds a fetch to an ordinary spot.

Lexer, facts and items:

30. **Lexer is total.** `unrecognized shader token` can never occur: every byte
    is a token, whitespace or part of a dropped comment. Hostile input cannot make
    the unterminated `/*` search quadratic.
31. **Numbers.** An exponent needs digits (`1e` is `1` then `e`). A string with a
    backslash before a line break is still unterminated at the line break.
32. **Comma.** A comma is a punctuation token, but `Token::operator()` answers
    `Operator::Comma` for it, so expression code treats it as the loosest operator.
33. **Summaries (R48).** The grouping tokens `( ) [ ]` are structure, never listed
    among a range's operators; `.` is. The member, index and call forms of the
    top-level classification apply only when nothing binds looser than they do
    (a deliberate difference from Q27: `p < q.x` is `other`, not a field select).
    Summaries are built to a nesting depth of 96 and a total work bound
    (2,000,000 plus 64 per token); past it a range simply has none.
34. **R44 and `struct`.** `struct Name inst;` is not a declarator statement (the
    keyword is not a type) but is a declaration item for R50.
35. **R47.** A function definition ends at its closing brace; any other simple
    statement that holds a block (a struct) continues to its `;`.
36. **Items.** A construct that reaches a brace before a `;` is reported as a
    one-token declaration and scanning continues with the next token (so `main`
    after a stray macro invocation is still found). A declaration stops at a
    directive or annotation token instead of swallowing it. A function may start
    with qualifiers; its item then starts at the first one. `type name (` whose
    parenthesis never closes is a parse failure at the `(`. Constructs longer
    than 2048 tokens are classified in pieces of that size (a hostile-input
    bound; real headers and declarations are far shorter).
37. **Conditional brace matching (R54).** Each arm of a conditional starts from
    the depth the conditional opened at, and after `#endif` the depth of the
    first arm is kept. A conditional opened before the scan started (the per-arm
    header shape) is treated as opened at depth zero. A body whose arms all close
    it ends at the completing `#endif`.

Metadata and protocol:

38. **Order of validation (R60, R63).** `default` is validated before the combo
    name is looked at, so a malformed number fails the shader even on a
    `[COMBO]` line that has no `combo` key. A value that starts with `e` or `E`
    has a numeric prefix and so fails (`e` does not parse).
39. **NUL in names (R10).** An alias whose material text, or a default texture
    whose path, contains a NUL byte is dropped silently.
40. **Texture slot text (R65).** `g_Texture007` is slot 7 here (the digits parse),
    while `names::classify_slot_name` calls the same text non-canonical: that
    function serves the response side, this rule serves annotations.
41. **Combo definition order.** Request combos in request order, then
    texture-derived combos, then annotation defaults, each in stage order and
    first-seen order (a combo found by both stages keeps the first stage's value).
    The texture-switch scan runs once, over the view built with the request
    combos alone; the annotation defaults come from one extraction over the
    evaluated text built for request plus texture-derived combos (Q4). The
    second evaluation is skipped when nothing was added.
42. **Errors of this step.** An unusable annotation is `RequestError::Metadata`
    (`invalid shader request: metadata number is invalid`, `... material alias is
    empty`); a bad combo name or slot reuses the existing variants. The include
    failures print the wording of R9 (`shader include not found: p.h`,
    `shader source read failed for p.h: ...`, `shader source utf-8 invalid for
    p.h`). A preprocessing failure is one diagnostic: stage, `Preprocess`, the
    line as its span, and an origin label (`include <path>`) when the line is in
    an include; `Diagnostic.origin` is a renderer-only field, not a key of the
    diagnostics document.

## Step 3 choices (dialect front end, type rules, conversions)

Design:

43. **Macros are expanded here.** Wallpaper Engine's compiler expands macros before it sees
    types, so every type rule (R20, R101, R102, R104a) is satisfied by expanding them once,
    before parsing; no rule has to look into a replacement list. `#define` and `#undef` lines are
    consumed in source order (a macro defined in a function body applies from there on); the
    converted text therefore carries no `#define` (spec 2.2 and 10.22 allow this; the few
    "definition stays present" checks are replaced by checks of the expanded meaning). Expansion
    follows the usual rescanning model with a hide set; a function-like macro name without `(`,
    or with the wrong argument count, is left alone; `#` and `##` are not supported (no shipped or
    workshop shader uses them). Replacement tokens take the span of the use. Bounds: 1,000,000
    produced tokens, invocations nested 64 deep in arguments.
44. **Comments.** Ordinary comments are dropped (the lexer drops them). WE annotation lines
    between top-level items are kept as written; inside a function body they are dropped.
    Strings pass through as tokens.
45. **Leniency.** The parser is a real C-like grammar. Only delimiter problems are hard failures
    (R6, reported at the opening delimiter, or at a closer that closes nothing). An item or
    statement the grammar cannot place is carried through as raw text for naga to judge (P3),
    and so is a stray character (R5, E19). Statements nest at most 128 deep, parenthesised
    expressions likewise, and an expression tree is at most 256 deep (hostile input becomes raw
    text instead of a stack overflow; `ast::Expr::depth` makes the check O(1)).
46. **Types are coarse** (`ty.rs`): scalars, vectors, float matrices, arrays, structs, samplers,
    `void`, and `Unknown`. `Unknown` switches every rule off for the construct (P3): a
    conversion is inserted only where both types are known. An undeclared name, a call of an
    undeclared function and a swizzle with letters of no set are `Unknown`.
47. **What naga does is measured, not assumed** (naga 29.0.3, checked with a harness before
    the rules were fixed): int to float and int to uint scalars convert implicitly in arithmetic
    and in initializers, uint to int does not, `vec3(bool)` is refused, `float(bool)` works,
    `mat3(mat4)` and `mat3(mat4x3)` work, float `%` works and writes Metal `fmod`, vector `%`
    scalar does not, `min(vec3, 2)` works, `pow(vec3, 2.0)` does not, a `for` condition that
    starts with a type name is read as a declaration, and the declarators after an array
    declarator in one declaration list get the array type.
48. **Conversions** (R23 to R45). Number to bool is `x != 0` with the zero of the number's type;
    bool to number is the constructor `float(b)`, `int(b)`, `uint(b)` (`vecN(float(b))` for a
    vector target); float to int and uint to int are constructors; int to float is a
    constructor for a variable and a rewritten literal (`3` to `3.0`, `2u` to `2.0`, `3`
    to `3u`); a vector narrows with a leading swizzle (`(expr).xy`), a scalar broadcasts with the
    constructor of the target type, a vector into a scalar takes `.x`. Widening a vector is never
    done (R32) except the one case of R31.
49. **Float `%` stays the operator.** naga's glsl-in accepts `%` on floats and the Metal writer
    emits `metal::fmod`, the remainder with the sign of the dividend (R47). The probe of
    `tests/gpu_probe.rs` checks that value on the GPU. So no helper function is generated: both
    operands become floats of one shape (an `int` side is converted, a scalar beside a vector
    is broadcast) and `%=` likewise. `fmod(a, b)` is the same operator. Integer `%` is untouched
    (R46) and `%` of unknown types is left alone (R50).
50. **Comparison of an integer with a float** compares as floats (`float(i) < x`), except that an
    integral float literal beside an integer counter is rewritten as an integer (`i < 4.0` to
    `i < 4`), which is R39's loop-bound case; `i < 2.5` compares in float.
51. **R31** pads a `vec2(...)` or `CAST2(...)` operand of `+` or `-` with a zero third component
    when the sum flows into a 3-vector (initializer, assignment or return) and the other operand
    is a 3-vector by type. Nothing else widens.
52. **`mul`** is `(b) * (a)` with the operands typed as a product (`mat4x3 * vec4` is a `vec3`),
    and two float vectors of one width are `dot(a, b)` (decided in the spec). A user two-argument
    `mul` wins for the calls it accepts. A user function whose name is also a built-in or dialect
    name wins only when every argument is known and matches without a change of shape (R65, R71);
    otherwise the dialect meaning applies.
53. **`ddy`** keeps the old compiler's `dFdy(-(x))`. The sign depends on the renderer's clip-space
    orientation, which a front-end test cannot see; parity with today's pictures decides it until
    a derivative probe in the renderer says otherwise (R15, open question 4).
54. **`smoothstep` with reversed edges** is not rewritten. The Metal probe
    (`tests/probes/smoothstep_reversed.swift`, run with `WM_SHADER_GPU_PROBES=1 cargo test --test
    gpu_probe`) shows that `metal::smoothstep(0.9, 0.4, x)` already returns the saturated-ratio
    Hermite curve of Direct3D, for edges the compiler can fold, for runtime edges and for
    vectors; R106 says nothing is rewritten then. Only the shape rules of R28 apply.
55. **Helpers** (`convert/helpers.rs`) are emitted only when used, once each, ahead of the first
    function, under the prefix `_wm_` (or `_wm1_`, `_wm2_`... when the stage uses an identifier
    that starts with it): `clip` for float and the vectors, and the stand-in
    `PerformLighting_V1` (both overloads, under its own name,
    emitted when the stage calls it and nothing declares it).
    The former matrix `inverse` helper was removed: Wallpaper Engine's HLSL rejects that
    builtin, while a shader's own inverse function remains an ordinary function (note 129).
56. **Array and sampler parameters** (R66, R67). A function with such a parameter is kept as a
    template and dropped from the output. Each call specialises it for the global array or sampler
    it passes: the clone is named `<name>_wm<N>` (N counts distinct specialisations), loses the
    parameter, reads the global (substitution respects shadowing locals and never touches member
    names), and is emitted ahead of the function that first calls it. An array parameter the body
    writes is copied into a local initialised from the global instead. A call that passes a local
    or computed value is refused with a diagnostic that names "array-parameter specialisation".
    `MAKE_SAMPLER2D_ARGUMENT(t)` is just `t`.
57. **Stage inputs the shader writes** (R75). The interface variable is declared as `_we_in_<name>`
    and the author's name becomes a global of the same type, assigned from it at the start of
    `main` (ahead of the moved global initializers). A write is an assignment, a compound
    assignment or `++`/`--` rooted at the input, or the input passed to an `out`/`inout`
    parameter; shadowing locals are told apart by scope.
58. **Global initializers** (R72): an initializer that is not built from literals, constants and
    constructors (calls of functions, uniforms, inputs, mutable globals, `gl_` names) moves to the
    start of `main`, in declaration order, and the declarator loses `const`; a declaration list is
    split so only the moved declarators change. A stage without `main` keeps its initializers.
59. **Reserved words** (R70) are renamed to `<name>_wm` (a taken spelling gets a number) for
    locals, parameters, struct fields, globals and function names, consistently across
    declaration and uses; `sample` is the qualifier only in a qualifier run in front of a type.
60. **Alpha-to-coverage** (R83, revised in note 137): authored sharpening is ordinary
    arithmetic and survives conversion, including derivatives and reads of the colour output.
    The renderer applies its result as coverage. No alpha expression is replaced by a prior
    source value.
61. **Builtin variables** (R88): `gl_VertexID` and `gl_InstanceID` read as the `uint` builtins
    `gl_VertexIndex` and `gl_InstanceIndex`; a restating `in`/`attribute`/`varying uint
    gl_VertexID;` is dropped; any other `gl_` declaration is left as written.
62. **Header and idempotence.** The text starts with `#version 450` and `precision highp float;`.
    An input `#version` line is dropped and a `precision highp float;` statement is not repeated,
    so converting the output again gives the same text. `#extension` and `#pragma` lines pass
    through in place.
63. **Spans and diagnostics.** A syntax failure (R6) has pass `Parse`; a refusal of this part
    (unsupported name, sampler3D coordinate, array-parameter specialisation) has pass `Codegen`
    and the span of the construct; success carries the one informational `Codegen` entry.
64. **Float swizzle on a scalar** (`f.x`, `f.xxx`, legal HLSL) was first left `Unknown` for naga to
    refuse; it is translated since the A1 repairs (note 120).

## Step 4 choices (interface and resource legalisation)

How it is built:

65. **A tree, not text edits.** The converter hands over a tree, so the legalizer rewrites the
    tree and prints it. The rules of C2 4.1 are therefore not a list of text edits that have to be
    merged: R2's order shows only through effects, R3(c) to R3(e) and R81 hold by construction
    (nothing overlaps, nothing is inserted into a span), and the new tests assert the effects (a
    sampling call is paired with its sampler although `tex2D` is renamed, a renamed local is seen
    by the coercions and by the alpha idiom, reads through a specialised parameter are narrowed,
    the colour output is renamed last, text inside a replaced span disappears with it). Generated
    declarations and helper functions are carried as raw text items; the printed stage is the
    header, `#extension` lines, the texture, sampler and chroma declarations, the block, the
    interface and colour output declarations, the plane helpers, then the author's items.
66. **Order of the passes for a program.** Both stages are parsed; qualified declarations with
    several names are split into one declaration each (no declarator is ever dropped, section 5);
    array bounds and varying widths are reconciled on the *parsed* trees (R36 changes the type of a
    declaration, and the converter must see the reconciled type, C1 R89); both stages are
    converted; the block, bindings and locations are planned from the converted trees; each stage
    is finished. A stage alone skips the cross-stage part and uses R31 and R41.
67. **Macros are already expanded** (C1), which settles three C2 items. R4 and R85 (rules acting in
    macro bodies, alias macros of widened arrays, function-like macros, an alias define with a
    trailing comment) hold because the use site sees the replacement. R39 and R18 both use the macro
    table *at the declaration*: R18 says a uniform bound uses the table at the end of the stage, so
    a bound macro redefined after the uniform declaration reads the value at the declaration here
    (no shipped shader redefines one). A bare `#define N` used alone as an array bound is 1 as C2 R39
    and D R15 say: the expander (Step 5) writes `1` for an empty object-like macro that stands alone
    between `[` and `]` (it applies to any array bound, a uniform's or a local's too; elsewhere an
    empty macro is still empty). The first version of Step 4 left it empty; that was a deviation
    from the spec and is fixed.
68. **R12 position-redirect output is not special-cased.** A `#define gl_Position p` with an
    `out vec4 p;` expands before this part sees it, so `p` is an ordinary vertex output that no
    fragment input matches (a vertex-only varying with a location). That is harmless on naga and
    keeps the rule that no name is special-cased.

Spec conflicts and the choice made:

69. **R56 stability refusal.** C2 R56 refuses a function whose calls pass different top-level
    arrays; C1 R66 prefers cloning the function per array. The converter clones (Step 3), so the
    refusal and its pinned message are not reproduced; the stereo audio helpers that call one
    function with the left and the right spectrum work. A black-box port of the upstream refusal
    tests will fail on this and the spec should be amended.
70. **R59 against C1 R83 (retired).** Both older specifications requested replacing alpha
    sharpening with its source alpha, differing only in how broadly they matched it. That
    replacement changes multisample coverage and can erase other sampling calls in the
    expression. Revision 5 removes it; the authored formula is preserved (note 137).
71. **R68 loop bounds, R65 `int` from `step`.** The converter compares a counter with a float
    bound as floats (`float(i) < n`, HLSL's meaning) and keeps `int(step(...))` as an integer with a
    cast, instead of C2's `int(n)` and `float q = step(...)`. Both compile and agree whenever the
    bound is integral; the spelling differs from the old code (section 10 item 23 allows it).
72. **R41 standalone numbering.** A stage legalized alone numbers its interface from 0 in source
    order, but an array or matrix takes one location per element or column (R34), not one: two
    variables on one location are refused by naga (`downsample_quarter` declares a four-element
    varying followed by more). Non-array stages number as R41 says.
73. **R9 `sampler3D`.** Kept samplers stay as written, except that `sampler3D` is split into a
    `texture3D` and a sampler like a 2D texture (C1 R105d asks for it; naga reads no combined
    sampler of any kind, so the kept form can never compile). Cube and the other kinds stay kept.
    Sampling calls with `textureGrad`, `textureOffset`, `textureProj`, `textureProjLod`,
    `textureLodOffset`, `textureGather` and `textureQueryLod` are paired with the sampler as well;
    `texelFetch`, `textureSize` and `textureQueryLevels` take the separated texture object.
74. **Block member types naga cannot hold.** naga validates no `bool` in a uniform block and its
    Metal output gives a two-row matrix (`mat2`, `mat2x2`, `mat3x2`, `mat4x2`) 8-byte columns where
    std140 has 16. A `bool` or `bvecN` member is declared `uint` or `uvecN` (the same four bytes per
    component) and read back as a comparison with zero. A two-row matrix, alone or in an array, is
    declared with four rows (`mat2` as `mat2x4`, 32 bytes, array stride 32, as std140 has it) and
    every read of it is the author's matrix constructed from the stored one (`mat2(g_Q)`, which takes
    the upper-left submatrix, and `mat2(g_Q[i])` for an element); a column or an element is then read
    from that value, and `.length()` is unchanged. Reflection reports the author's component count
    (`mat2` 4) and the real offset, size and stride; naga would say 8 components, so the pipeline
    restores the count from the block plan after reflecting (D R99, D test 24). Arrays of booleans
    have no widened form and are refused with an "invalid request" message naming the member (R87
    allows the refusal). Integer arrays are widened to `ivec4` or `uvec4` (R87); the test
    `a_narrow_uint_array_stays_tight_on_metal_without_the_widening` shows that naga writes a plain
    `uint[3]` with a four-byte stride, so the widening is needed.
75. **Whole-array reads of a widened array** (`float bins[16] = g_Audio;`, an argument passed on)
    are an array constructor of the author's element type reading each element with its selector
    (R58 asks for the declaration to be erased and the uses replaced; the copy is the same work as
    the old copy and needs no scope analysis). Longer than 4096 elements is refused.
76. **Interpolation qualifiers** `flat`, `smooth` and `noperspective` are carried over to the
    re-emitted declaration (section 10 item 17); `centroid`, `sample` and precision words are
    dropped.
77. **A vector `uniform` declared wider in one stage** (R19) is read through `(name.x)` style
    parentheses by the narrower stage: the tree has no `#define` to carry, so the stage's reads of
    the name are rewritten (hidden by a parameter or local of the same name, they are not).
78. **Errors.** "Invalid request" failures are `LegalizeError::Request` (message only) or
    `LegalizeError::Uniform` (the contract wording of `UniformError`); `ShaderError` gained
    `RequestError::Program` for them. The stage-local and cross-stage classes carry a
    diagnostic (pass `Codegen`, the stage, a span of the preprocessed text). Messages: the pinned
    ones are produced word for word (unsupported member type, conflicting declarations,
    "cross-stage varying `x` type mismatch: vertex outputs T1 but fragment inputs T2",
    "unsupported stage-interface array bound", "cannot be sampled as planes", "canonical"); the
    metal limit text names the "argument-table limit of 15".
79. **Names the legalizer picks** (C2 2.4, free): the colour output `_we_FragColor`, synthesized
    vertex outputs `_we_out_<name>` (then `_N`), the plane helpers `_we_plane<N>` and
    `_we_nv12_convert<N>` (a pure function of the eight constants, so the arithmetic can be
    evaluated on its own), written inputs `_we_in_<name>` (the converter's). A taken spelling gets
    `_1`, `_2`, ...
80. **Not done in this step**: R79's optional early failure for a program the engine would refuse
    (a texture with another name, a kept sampler); the cache key and pipeline revision (nothing of
    this part reaches a compiled program until the pipeline calls it); the reflection document and
    the MSL writer call (done in Step 5); the engine-side binding of non-`g_Texture<N>` resources.

Results of the corpus sweeps (`cargo test --lib legalize::tests::corpus -- --nocapture`), three combo
sets, both stages together, every stage compiled through naga to Metal:

- Shipped shaders: 164 of 165 programs legalize and compile. The one failure is
  `shadowcasterfoliage4` (skinned and reflective): its vertex stage reads `g_Texture1Texel`, which
  no shipped file declares, so no translator can compile it; the test names it and fails on any
  other cause.
- Workshop shaders (unpacked copies of the local library, distinct file texts): 855 of 870 programs.
  The 15 failures are not this part's: `textoutline7x7` has a 49-element varying (model limit 31
  locations, R30; 3 programs), `frame_builder` contains text that is not GLSL
  (`varying vec4 v_Size . xy ;`; 6), `phantomtransitionfx` reads an undeclared varying (3) and
  `lens_distorsion` has a `#if` expression the preprocessor refuses (3).
- Mutation fuzzing of the shipped programs (3,000 edited programs) and truncation of a stage at every
  character: no panic.
- Stage by stage (the dialect sweep through the standalone entry point): 317 of 318 shipped stages;
  the 27 workshop failures are the ones above plus a varying width only the program can reconcile.

## Step 5 choices (pipeline, Metal backend, reflection)

Conflicts between the parts, and what was chosen (part D is the later and more specific spec for
anything that reaches the engine, so it wins unless noted):

81. **Metal slots (D R46 against C2 R88 and A R35).** Every record of a stage gets as its `slot` the
    rank of its binding among the stage's resources of the same kind, counted from 0 (ties in
    declaration order), for buffers, textures and samplers alike. `binding::assign_stage_slots` does
    it; C2's program-wide sampler ranking and its `assign_metal_slots` are removed, and the one
    legalizer test that used them now asks the per-stage function. A binding record per resource
    global of the module in declaration order, used or not (R45), named by the declared GLSL
    identifier (the type's name for an instance-less block, so `GlobalUniforms`).
82. **Order of the backend checks.** The binding map (R45 to R47, R46) comes before validation, so a
    resource the Metal target cannot take is reported as such even when the module would also fail
    validation under the default capabilities (an acceleration structure, push constants). A rank
    beyond the namespace limit is `BindingError::SlotLimit`, category `Reflection`, produced before
    any MSL is written; the other map failures are `MslWrite` diagnostics.
83. **Failure classes.** `ErrorCategory` has `InvalidRequest`, `SourceRead`, `Preprocess`,
    `Legalization`, `Compile`, `Reflection`, `Internal`; the class of a source failure follows the
    pass of its first diagnostic (`Preprocess`; `Parse`, `Legalize`, `Codegen` are legalization;
    `GlslParse`, `Validate`, `MslWrite` are compile; `Binding`, `Reflection` are reflection). A stage
    whose module has no entry point of its kind is `ShaderError::NoEntryPoint` (compile); naga's own
    front end already says "Missing entry point" for a text with no `main`. Two stages that reflect
    one block differently are an invalid request (R33), not a reflection error. A cross-stage
    failure carries the origin `cross-stage interface check`; other legalizer diagnostics carry
    `preprocessed <stage> source`, and the stage text is attached so the line shows (R10, R13).
84. **Validation.** `Validator::new(ValidationFlags::all(), Capabilities::default())`, so no
    early-depth-test, clip distance or subgroup capability (a shader asking for one fails at the
    `Validate` pass). The earlier sweeps validated with all capabilities; the corpus numbers did not
    change. Reflection reuses the usage information of that validation (R53 allows it);
    `reflect_untranslated` validates with every capability for a module built without GLSL.
85. **Vertex input types with no format (R59).** naga's validator refuses matrix, bool and 64-bit or
    16-bit location arguments (`NotIOShareableType`) before reflection can see them, so through the
    pipeline they are compile errors; the reflection error exists and is tested on the input reader
    directly (`inputs_of`). A struct-typed entry argument is flattened to its location members.
86. **Limits (D R61 against A R36).** Vertex location at most 30, descriptor set at most 3, binding
    index at most 31, texture slot at most 31; `g_Texture32` to `g_Texture255` say `model limits`,
    256 and up say the slot suffix is invalid. The legalizer's own check of the highest binding
    (C2 R30) stays for `legalize()` but the pipeline switches it off (`unlimited_bindings`): the
    texture `g_Texture32` has the encoded binding 32, and D wants that to be a reflection error only
    when the stage uses the texture. The interface location limit of the legalizer (31) is unchanged.
87. **Reflection details.** Descriptor kinds sort by their labels (`combined_image_sampler`,
    `sampled_image`, `sampler`, `uniform_buffer`), vertex inputs merge by location (first stage wins),
    a block is named by the instance name when the GLSL gives one and by the type name otherwise, a
    used uniform global that is not a struct or has no binding is an error while an unused one is
    absent, a used storage buffer or storage texture is an error naming resource, set and binding.
    Vertex inputs go under the author's name through `InputNames` (the legalizer's `_we_in_<name>`
    copies are mapped back, R58).
88. **Compiler identity (D R37 against A R77).** `<revision>:naga-<version>-msl<version>-<options>`
    (`1:naga-29.0.3-msl2.0-untransformed`), so it has the `<integer>:<text>` form and mentions no
    SPIR-V. Revision 1 was never shipped, so the golden key row was replaced, not appended.
89. **Cache key.** The plane marker is hashed for every texture record that is flagged, also for a slot
    the program never declares (A R82, a conservative reading of D R35, which says "compiled as
    planes"): such a flag changes the key but nothing else. Combos stay hashed in sorted order.
90. **Combo order (D R2 against B).** B's order is kept: request combos, texture-derived ones, then the
    annotation defaults; any fixed order is allowed by B. D's test 3 "added defaults appear as macros in
    the legalized text" is tested by effect (the branch they select is present), because Step 3 expands
    macros and the legalized text carries no `#define`.
91. **Array bounds (D R15, R23).** `3u`, `0x4`, `2.0`, zero and negative numbers are refused; the
    lexer reads `0x4` as `0` then `x4` (B pins that), so the parser keeps the tokens of a bound it
    cannot place as one opaque expression, written as in the source. The message quotes the bound
    as written in the stage text and, when macros changed it, what it was read as. An uninterpretable
    uniform array suffix names the suffix, the member and the stage (`vertex stage (Vertex)`).
92. **Pass-through samplers** (`samplerCube`, `sampler3D` kept as written, integer samplers) pass the
    legalizer and reserve their index, but naga reads no combined sampler, so a program with one fails
    at the `GlslParse` pass (compile); that is "such a program does not draw natively" (D section 10
    item 12).
93. **Block types and parity.** Superseded for two-row matrices by NOTES 74: they are widened and
    the layout test checks them with every other type (26 single types and 23 array types, alone and
    in mixed blocks, by parsing the MSL struct). Arrays of booleans stay refused naming the member;
    none of the shipped or workshop shaders uses one.
94. **MSL text facts measured** (naga 29.0.3): the first line is `// language: metal2.0`, the entry
    function of `main` is `main_`, a global whose name ends in a digit is written with a trailing
    underscore (the records keep the GLSL name), an array varying becomes one stage-in/out member per
    element with consecutive `[[user(locN)]]`, arrays in the block are wrapped in a struct `{ T inner[N]; }`,
    float literals are written with the shortest decimal that reads back (checked bit for bit over
    600 random values and the edges). The writer appends `center_perspective` after `[[user(locN)]]`.
95. **The system Metal compiler check** (`tests/metal_compile.rs`, opt-in with
    `WM_SHADER_METAL_COMPILE=1`) uses the compiler service the host uses
    (`makeLibrary(source:options:nil)` through `tests/probes/compile_msl.swift`), because `xcrun metal`
    needs the Metal Toolchain component, which is not installed here, and installing it is not ours
    to do. With `WM_SHADER_METAL_COMPILE_CORPUS=1` it compiles the shipped and workshop corpus too.

Results (`cargo test --release --lib pipeline::tests::corpus -- --nocapture`; a pair with a missing
file is not a program the engine compiles, so such pairs are left out; `HLSL/` and `volumetricsfront`
as in the earlier sweeps; three combo sets: none, lit and fogged, skinned and reflective):

- Shipped shaders, whole pipeline to MSL and reflection: **158 of 159 programs**. The failure is
  `shadowcasterfoliage4` under the skinned set: its vertex stage reads `g_Texture1Texel`, which no
  shipped file declares (`Unknown variable: g_Texture1Texel` from naga's front end). The sweep names it
  and fails on any other cause. No binding record carries a name outside the host's vocabulary
  (`GlobalUniforms`, `g_Texture<N>`, `_we_Sampler_g_Texture<N>`, the chroma pair).
- The same with slot 0 flagged as NV12 planes: 155 of 159; besides the foliage shader, `fur4` (3
  programs) is refused with the R63 message because it samples slot 0 with an explicit level.
- Workshop shaders (distinct pairs of the local library): **798 of 813 programs**. The 15 failures are
  the ones Step 4 explained and none is new: `frame_builder` has text that is not GLSL (`varying vec4
  v_Size . xy ;`; 6), `phantomtransitionfx` reads an undeclared varying (3), `textoutline7x7` has a
  49-element varying above the interface limit of 31 locations (3), `lens_distorsion` has a `#if`
  expression the preprocessor refuses (3).
- The system Metal compiler (default options, as the host) accepted all 316 stages of the 158 shipped
  programs and all 430 stages of the 215 distinct workshop pairs it was given (plain combos): zero
  refused.
- Time (release): per program median 0.4 ms and worst 5.2 ms for the shipped ones, median 1.0 ms and
  worst 3.5 ms for the workshop ones, preprocessing and reflection included.

## Opt-in physical uniform-layout diagnostics

`observer-uniform-layout` retains compiler-origin observations from each original
translated Naga module before that module is dropped. It is disabled by default:
ordinary stages have no diagnostic field, traversal, allocation or extra reflection
bytes. No extra C function is added. With the feature enabled, the existing
`rs_shader_program_reflection_json` document adds `observer_uniform_layout` schema1.
The compiler/cache identity gains an explicit diagnostic suffix so these responses
cannot be confused with ordinary cached programs.

Each stage owns its source/emitted entry names and active block/member identities,
offsets, physical byte spans, scalar kind/width, vector or matrix dimensions,
matrix-column stride and outermost-first array dimensions/strides. These are the
translated storage types: a Boolean may be unsigned storage, a two-row matrix may
have four physical rows, and a scalar array may use padded vectors. Ordinary
authored component counts remain separate. Matrix-column spacing comes from
Naga's row-vector alignment rule, not from dividing a guessed byte span or reusing
the whole-array stride.

Unavailable modules/entries/types and exceeded observation budgets are explicit;
a consumer must refuse `complete == false`. Limits per stage are 128 blocks,
4096 members, 16 array dimensions per member and 256 KiB of copied names. Array
elements are not expanded. Nested struct members and nonconstant arrays remain
unavailable; their presence does not change ordinary shader compilation success.

From the repository root, exercise both ordinary and diagnostic configurations:

```sh
python3 scripts/check_rust.py --observer-uniform-layout
```

The extra `shader-observer` stage does not replace the ordinary stage. Actual C
consumer builds inherit their test binary's feature selection. Normal and observer
C callers were also exercised on the same independently authored request: ordinary
reflection, annotation metadata, MSL and stage payloads matched; compiler/cache
identities differed; the diagnostic returned physical Boolean, widened matrix and
padded-array facts through the existing accessor. These are compiler/ABI checks,
not evidence that a native Metal draw used that layout or those bytes. An observer
must still join the selected ordinary/variant program to actual bound buffers,
draws and resource lifetimes; this feature does not perform that capture.

## What a later step takes from this one

The C ABI (`ffi` feature): `pipeline::compile` returns a `CompiledProgram` with everything the
response documents hold (`StagePayload::to_json`, `Reflection::to_json`, `Metadata::to_json`,
`diagnostics_json`, `cache_key`, `compiler_identity`); failures are `ShaderError` with `Display` as
the last-error text. The include provider of the C ABI implements `IncludeSource`.

## Not yet done (planned for later steps)

The engine-side checks of test 34 (draw tests) and the engine-side items of spec A section 8 (the
request builder, the merge contract, R107's refusal, the golden check of R88 against the engine's own
documents). R79's optional early failure for a program the engine would refuse.
`src/dialect/tests/boundary.rs` pins a digest of the converter's output per `PIPELINE_REVISION`, so the
first change of converted output after that revision forces a deliberate bump. Arrays of booleans in
the block (NOTES 93).

## Step 6 choices (the C ABI)

96. **Thirteen functions, no SPIR-V accessors.** The spec lists fifteen exports "today" and thirteen
    after plan phase 2d, with the two `spv` accessors deleted. This crate is the post-2d layer (the
    target `vulkan_spirv` is a request error), so only the thirteen exist, in the header and in the
    archive (a test lists the archive's `rs_shader_` symbols with `nm`). A swap step that links this
    archive in place of the old one must land with the engine change of 2d that stops declaring them.
    `rs_shader_program_stage_target` is kept (always 1).
97. **Library file name.** The package is `wm-shader`, so the archive is `libwm_shader.a`
    (`target/<profile>/`), not `libshader.a`. The swap step points the engine's build at it (spec 2.8 names
    the file; it is a build detail, not part of the C contract). The host-callable initialiser of 2.8
    (Q15) was dropped here and is back since amendments 1 (R113(b)): `ffi::keep_exports_alive`, see
    note 113.
98. **Error wording of the pointer checks.** `compile request failed: the request pointer is null` and
    `... the out program pointer is null` (R2). With both null the request pointer is named. The
    out pointer is set to null before anything else, so every failure path leaves null (R1), even the
    null-request one.
99. **Nullable function pointers.** The callback and the callback's `free` are `Option<unsafe extern
    "C" fn ...>`, which has the layout of a nullable C function pointer. `RsShaderOwnedBytes` is
    `repr(C)` with the four fields of 2.3, in that order. A `free` set with a null `ptr` is never
    called; `ptr` non-null with `len == 0` is an empty include and is freed (with `len` 0). A buffer
    is released by a drop guard, so it is freed once on every path out of the read (copy, bad UTF-8,
    unwinding), after the bytes were copied. A length above `isize::MAX` with a non-null pointer is
    treated as "could not read" (the bytes are not touched) and the buffer is still released.
100. **NULs.** Every string handed to C goes through one conversion that turns a NUL into a space (R5):
    stage text, the five documents, the key, the last error. JSON documents cannot contain one
    (the writer escapes it); MSL text can only if the source did, and then it is refused earlier.
101. **Last error.** A thread-local `CString`; `rs_shader_last_error` returns its pointer, and a compile
    replaces the buffer, so the pointer is valid until the same thread's next compile (R70). A thread
    that is being torn down gets the static text `no shader error`.
102. **Panics and the panic hook (R4, R93).** The body of a compile runs under `catch_unwind`; a panic
    becomes status 1 with `the shader layer failed internally: <message>`. The default hook would
    write that panic to standard error, which R93 forbids for the layer. A hook is installed once, on
    the first compile, that stays silent while the panicking thread is inside a compile (a
    thread-local flag, restored after nesting) and otherwise calls the hook that was there before.
    This is the one process-wide effect of the library; a host that installs its own hook later
    replaces it and merely gets the default message back. A test mutates the hook away and sees it
    fail. A panic inside the C callback cannot be caught (the callback is C), as the spec says.
103. **Unsafe confinement.** `#![deny(unsafe_code)]` for the crate with `#[allow(unsafe_code)]` on
    `mod ffi`; without the feature there is no unsafe code at all. Every unsafe block says what it
    relies on. The accessors are `unsafe extern "C" fn` in Rust (raw handle in), plain C functions to a
    caller.
104. **No test hook in the library.** The forced internal failure of section 8 is a `#[cfg(test)]`
    thread-local in `ffi`; a build without `cfg(test)` has no hook and no way to trigger one.
105. **R91 on the downstream compiler (a real finding).** naga's GLSL front end, validator and Metal
    writer recurse over nesting. With only the earlier parts' bounds, 320 nested parentheses, 209
    nested calls, 138 nested `if`/`for` blocks, 480 chained `+` or unary minus, or 280 `else if`
    links overflowed a 512 KiB stack in a release build (the C ABI test with 1,000 parentheses
    aborted the process). The layer cannot start a thread (R89) and cannot patch naga, so
    `backend::depth::stack_cost` measures the legalized text before it is handed over: each open
    bracket adds a weight (block 4, parenthesis or index 3), each operator or member access in an
    expression still being read adds 1, each statement head (`if`, `for`, `while`, `switch`, `do`) and
    each `else` link adds 3 until its body ends (the `;` or the closing `}` of the body, unless an
    `else` follows; a `do` until its `while`), and the largest running total is the measure. Without
    that last rule `if (c) if (c) ... x = 1.0;` (300 deep, no bracket), an unbraced `else if` chain
    (280 links), and the same with `for`, `while` and `do` overflowed the stack; a review found them
    after the first version, which only counted braced bodies. Over `STACK_BUDGET` (128) the stage
    fails at the `GlslParse` pass with a message that gives the measure and the limit.
    Nesting of types is the one recursion with no bracket at all: a chain of structures each
    containing the previous overflowed at about 1,900 levels. `depth::struct_depth` reads the longest
    containment chain from the text (members name structures declared before them, so one pass) and
    a stage over `STRUCT_DEPTH_LIMIT` (64; real shaders nest two or three) fails the same way. The
    ABI tests run both families of hostile text, and a calibration test takes the deepest accepted
    nesting of ten shapes (statements, blocks, parentheses, sums, structures) and compiles it on the
    small stack; a braced `if` costs 7 a level, so about 17 nested braced `if`s pass. Calibration (release build, naga 29.0.3): one unit costs at most
    about a kilobyte in the worst shape; a random mix of nested statements and expressions at a
    measure of 128 (2,200 accepted inputs over five seeds, all compiled) needs between 96 and 128 KiB, so
    the budget has a margin of four on 512 KiB. The deepest shipped stage measures 47, the deepest
    workshop stage 37 (the corpus tests print it and fail above 64). An unoptimised build needs far
    more stack (a mixed input at 128 overflowed 2 MiB), so the ABI test runs on 16 MiB in a debug
    build and on 512 KiB in release, with `WM_SHADER_TEST_STACK_KIB` to probe; the release bound is
    the one that is specified. The hostile ABI test passes in release down to 256 KiB (128 KiB
    overflows in the earlier parts), so the margin of the whole pipeline is two at the plain minimum.
    No `PIPELINE_REVISION` bump: output for every accepted request is unchanged and only an
    absurdly deep text that used to compile is now refused.
106. **Includes through the callback.** The path handed to the callback is the validated, normalised
    one; a path with a NUL, which the preprocessor already refuses, would be reported as invalid
    rather than reaching C. The provider is wrapped by the preprocessor's `CachingSource`, so a path
    is asked for at most once per compile (R22), checked by a test with both stages including it.
107. **Debug-build tests of the C program.** `tests/c_abi.rs` runs `cargo build --lib --features ffi`
    in its own profile and target directory (the library is built for `rlib` only when a test needs
    it) and skips with a printed reason without clang, nm or the build; the C program's stdout and
    stderr must be exactly `c abi ok` and empty, which doubles as the check that a failed compile
    writes nothing (R93).

## Amendments 1 choices (a-contract R111 to R113, b R81, c1 R107, c2 R90, d R66)

The amendments are in `.plans/own-code/specs/shader/amendments-1.md`. What it leaves open, and the
reading chosen as the most consistent with it:

108. **Member-access suffix (c1 R107).** The suffix is a dot, then one identifier whose letters are all
    component letters (`xyzw`, `rgba`, `stpq`, mixed freely: it is discarded, so no set has to be
    consistent), then `;` or `,`. It is read only directly after the declared name, not after an array
    suffix (`v[2].xy` is not tolerated). It applies to every top-level declaration that carries one of
    `uniform attribute varying in out`, so there is one code path; a declarator list accepts a suffix on
    each declarator. Anything else after the dot, a number the lexer made of the dot (`v.12`), a
    non-component identifier or a following `=`, `[` or `.`, is a hard parse failure, reported by
    `dialect::parse` as a `Parse` diagnostic spanning the declaration from its first token through its
    `;`. The tree drops the suffix, so the converted text, reflection and Metal text are those of the
    plain declaration (the cache key still differs: it hashes the raw source, note 9) and the use facts
    of R7 never see it.
109. **Metadata scan (b R81).** Nothing changed: the item scan reads a declaration up to its `;`, so a
    suffix stays inside one declaration whose name is the identifier before the dot. Tests pin it for
    the compiled and the conditional shape and for annotations after the declaration.
110. **Component budget (d R66).** `legalize::interface::check_component_budget` sums, in source order,
    the components of the fragment stage's varying inputs after the width reconciliation (scalar 1,
    vector N, matrix columns times rows, arrays multiply, a type it cannot size counts 4). It runs in
    the program numbering and when a fragment stage is legalized alone; a vertex stage alone, and vertex
    outputs no fragment input names, are free. The failure is a `LegalizeError::ComponentBudget` (category
    `InvalidRequest`, note 143) naming the total, 124, the stage and the varying whose addition first crossed the
    limit. Location numbers of varyings are unbounded (running totals saturate instead of overflowing, so
    a hostile array bound cannot panic a debug build). The location cap of 31 stays for vertex inputs
    and fragment outputs, and reflection still refuses a vertex input above 30 (d R61), the stricter
    figure winning as c2 R90 says. A vertex-only varying array with an enormous bound is not limited
    by the budget (it is free by the amendment); it is only as costly as naga makes it.
111. **Target and accessors (a R111).** Already true of the code; added: the header says target 0 is
    retired, never returned, never reassigned; a C caller that declares only the thirteen functions
    (`tests/c/thirteen_only.c`) links and compiles a quad; tests refuse the Vulkan spelling, the empty
    string, a made-up name, a wrong-case Metal name and a target of the wrong JSON type, each with the
    request-parse marker and the offending string, and show that an omitted target and `metal_msl` give
    identical documents. No name exists for the retired target in the header.
112. **Parity corpus (a R112, check 4).** The golden files "recorded from the old library" cannot be
    made from this side of the clean room. `tests/golden/parity/` holds metadata and reflection documents
    of three fresh programs recorded from this library (bless with `WM_SHADER_BLESS=1`), and the shipped
    and workshop sweeps of the crate's tests (printed pass rates, skipped with a reason when the tree is
    absent) stand in for "every program that compiled then compiles now". The real parity comparison
    against the retired library's documents is for the swap step, which has both.
113. **Host linkage (a R113).** The package and archive names were already `wm-shader` and
    `libwm_shader.a`. `ffi::keep_exports_alive()` is the one documented host-callable entry: it returns
    the address of `rs_shader_compile_program` and is not exported to C. A test checks that it names that
    function, that there is a single such entry, and that the archive still exports only the thirteen
    names; another that no manifest of the workspace but this crate's names it. Not done here, because it
    is the swap step's and lives outside this worktree: the engine's `RUST_SHADER_STATICLIB` configure
    step, the release gate and the renderer and Rust check scripts, the licence-check fixtures and the
    architecture and build docs, which still name the old crate in the old workspace (changing them
    before the old crate leaves would break the gate that still builds it). The engine-side obligations
    of R111(d) (removing the two accessor declarations, compiling each program once for Metal, removing
    the Vulkan-renderer tests) are the engine's.
114. **Slots (D5).** The code already implements d R46 (per stage, per namespace, rank by ascending
    binding, gap-free); `binding.rs` documents that the R35 limits apply to the dense slot and that the
    block is buffer slot 0 as the stage's only buffer. Tests pin the properties of D5 (1) to (5). The
    sixteen-sampler positive case cannot be written with canonical texture names (sixteen textures, their
    samplers and the block need 33 binding numbers, and R30 caps bindings at 31), so the limit is pinned
    from above (seventeen fail with the argument-table text) and by thirteen below.
115. **Plane block order (D6).** The code numbers the block before the chroma resources in the plain
    layout (block 4, chroma texture 5, sampler 6 in the amendment's example), which the relaxed rule
    allows. The two tests that pinned block 2 and chroma 3 now assert only uniqueness, the author's
    bindings unchanged, and the chroma bindings above the author's; no test orders the block against the
    chroma resources.
116. **Identity (a R77).** `pipeline/tests/golden.rs` records a digest of the Metal text of three fixed
    programs per identity (append-only, revisions strictly increasing and equal to the newest row), so a
    change of output without a new identity fails. `PIPELINE_REVISION` stays 1: output of every program
    that compiled before is unchanged; programs that failed before (a suffix, a varying past location 31)
    now compile. The diagnostics test checks `Codegen` and a span with start not after end through the C
    ABI; that the span lies inside the stage text is the diagnostics module's own test (R73).
117. **D4 and D8 (confirmed, left alone).** Tests pin c1 R58, R52 and R53 with c2 R62, R11 and R67 at any
    parameter position beside `in`, `out` and `inout`. No macro name is added (the `SAMPLERND` spelling of
    the report is read as the 2D one). Cosmetic Metal differences (D8) are not pinned beyond the digest
    of note 116; the scene crash and poster noise (D9) are not a shader-layer matter; no timing assertion
    was added (H2), the 512 KiB stack test stays.

Pass rates after these amendments are in the final report of the change: the workshop pipeline sweep
compiles 807 of 813 programs (798 before), the dialect sweep 1,665 of 1,680 stages (1,653 before); the
remainder is an undeclared varying (`phantomtransitionfx`), a `#if` the preprocessor refuses
(`lens_distorsion`) and `v_TexCoord.zw` on a two-component varying, none of them in the amendments.

## A1 repairs (declarator lists, integer `clamp`/`min`/`max`, scalar swizzles, run-time `#if`)

Four general repairs of behaviour a release of the earlier implementation had. The tests are new files:
`tests/declarator_lists.rs`, `tests/integer_clamp_min_max.rs`, `tests/scalar_swizzles.rs` and
`tests/runtime_if_conditions.rs`, with the shared `tests/support/` (a pipeline helper, naga IR queries, and
the GPU kernel runner of `tests/gpu_probe.rs` behind the same `WM_SHADER_GPU_PROBES=1`). What the earlier
steps had already done is noted; those tests passed before the change and stay as proof.

118. **An array suffix types one declarator.** Already done by the converter (`stmt::needs_split`): a local
    or global list with an array declarator before another declarator is written one declaration per
    declarator, each with the list's qualifiers and type; constants, constructor initializers and brace
    lists included. Uniform, varying and attribute lists are split by the legalizer (note 66), so
    `uniform float a[4], b;` declares `b`, and the metadata scan reads the source, so an annotation keeps
    binding to the list's first name (R50). New: a `for` initializer split that way became a `Seq` the
    loop header cannot print, and its declarations were dropped; they now go into a block of their own
    around the loop. A list without an array declarator, a `for` initializer included, is unchanged, and
    struct members and parameters are never split.
119. **Integer `clamp`, `min`, `max`.** Already the rule of `call::shape_args`: with every argument typed and
    none float, the call keeps integer literals (`uint` operands make them `3u`); a float operand turns
    them into floats. Two readings of the packet: a call of literals only stays an integer call (the
    rule in force since Step 3; its value is the same, and it converts where a float is needed), and the
    converter has no repair that rewrites an `int` declaration to `float` (note 71 keeps `int q = step(...)`
    an `int` with a conversion), so the "an int the step repair made a float" case cannot arise.
120. **Scalar swizzles** (supersedes note 64). A swizzle of a scalar whose letters all name component 0 of
    one set (`x`, `r`, `s`, one to four of them) is that scalar repeated: one letter is the value itself
    (so `f.x = 1.0` writes `f`), more are the constructor of the scalar's kind and that width (`vec3(f)`,
    `ivec2(i)`, `bvec2(b)`), which evaluates the scalar once. The result is typed, so the width rules apply
    to it like to any vector (narrowing into a `vec2`, truncation beside a wider vector, `.x` into a
    scalar). Any other letter (`f.y`, `f.xy`) stays `Unknown` and naga refuses it. Names resolve through the
    converter's scopes, so a scalar shadowed by a vector (or the other way) is swizzled by the declaration
    in scope. A scalar initialised from a vector expression was already the first component of the whole
    converted expression (`coerce` narrows last); the tests pin that with consumers that reorder components
    and check that a sample reaches `max`/`mix` whole.
121. **A condition about run-time values is false.** `#if g_Texture0Resolution.x < g_Texture0Resolution.y`
    used to stop preprocessing. `expr::runtime_token` looks for a token no preprocessor expression can hold:
    a `.` after a name, a number or `)`, or a character outside names, numbers, parentheses and the C
    preprocessor's operators (`[`, `,`, a quote). When the strict evaluator fails on such a condition, the
    condition is false (its `#else` or a later `#elif` is taken) and the preprocessor records a diagnostic
    (pass `Preprocess`, the stage, the directive line as span, `include <path>` as origin inside an
    include). `StageOutput::diagnostics` carries it, `PreparedStage::diagnostics` keeps the final evaluated
    pass's entries, and the program lists them ahead of the legalizer's. At most `MAX_CONDITION_NOTES` (16)
    are recorded per stage and one more entry counts the rest, so a hostile stage cannot grow the stored
    diagnostics document; the engine only copies that document. Conditions made of preprocessor
    tokens behave as before, including the refusals R24 to R26 and the existing tests pin: `defined(X)`,
    arithmetic (so `X / 0` too), `?:`, `0x10`, `1u`, `2.5`, an opaque value or an undefined chain in a
    comparison, unbalanced parentheses, an empty condition. A condition that has both a run-time token and
    a structural fault (`(g.x < 1`) is false, since it is not a preprocessor expression at all.
122. **Pipeline revision 2.** Naga refuses every scalar swizzle and an unevaluable condition failed the
    request, so repairs 120 and 121 change no response that succeeded before. The `for` fix of 118 can: a
    loop whose names resolved to outer variables after its declarations were dropped compiled, with other
    meaning. That is enough under `identity.rs`'s rule, so the revision is 2. The fixed programs of the golden
    tables translate to the same Metal and converter text; only the cache key row is new.

The shipped sweeps are unchanged (158 of 159 programs, 317 of 318 stages); the system Metal compiler accepted
all 316 shipped stages. The workshop sweeps could not run in the worktree of this change (no unpacked
copies): `lens_distorsion`, refused before by the preprocessor, now goes further and has to be checked there.

## WE dialect parity (Wallpaper Engine 2.8.0.42 prelude)

123. **Texel fetch, back buffer, comparison** (WE prelude `sub_1400D5070` / `sub_1400F5CB0`; supersedes the
    R22 refusals of `texLoad2D`, `texSample2DBackBuffer`, `texSample2DCompare` and
    `sampler2DComparison`). The reference prelude defines `texLoad2D(s, u, r)` as
    `s.Load(int3((u) * (r), 0))`, written `texelFetch(s, ivec2((u) * (r)), 0)`;
    `texSample2DCompare(s, u, d)` as `SampleCmpLevelZero`, written `textureLod(s, vec3(u, d), 0.0)`
    on a `sampler2DShadow`; `texSample2DBackBuffer(s, u, r)` as `s.Load(int2((u) * (r)), 0)` of a
    `Texture2DMS<float4>` under `BACKBUFFER_MS` and `texSample2D(s, u)` otherwise. The converter
    renames `sampler2DComparison` to `sampler2DShadow` and `sampler2DBackBuffer` to `sampler2DMS` or
    `sampler2D` before it converts (`ConvertOptions::backbuffer_ms`, set by the pipeline from the
    effective `BACKBUFFER_MS` combo). `DECLARE_SAMPLER2D_COMPARE_PARAMETER` and
    `MAKE_SAMPLER2D_COMPARE_ARGUMENT` are the comparison twins of the 2D parameter macros. Only
    `textureCompare`, which the dialect does not have, is still refused among these sampling names.
124. **Split kinds.** `TexKind` has `Shadow` (`texture2D` object, `samplerShadow` sampler, joined as
    `sampler2DShadow`) and `D2Ms` (`texture2DMS`, joined as `sampler2DMS`); `TexturePlan::kind`
    replaces `three_dimensional`. A `texelFetch` is left on the texture object, as Naga reads it.
125. **Reflection says what to bind.** A sampled image carries `"dimension"` (`3d`, `2d_ms`,
    `depth_2d`, `other`) when it is not a plain 2D texture, and a comparison sampler
    `"comparison":true`; plain records are unchanged, so no golden reflection moved. The engine
    binds a stand-in of the declared type, reading zero, when a slot's texture is of another type,
    and a GREATER comparison sampler with a transparent border for a comparison slot.
126. **Untyped operands** (R54, R55 widened). An operand of `!`, `&&`, `||` or a condition whose type
    the converter does not work out (`ldexp`, an unresolved
    macro name) is written `bool(x)`, the identity on a bool and "not zero" on a number; a store of
    one into an `int`, `uint` or `float` is that type's constructor. Vectors are never wrapped.
127. **Initial changes kept revision 2.** The shipped golden tables (`pipeline/tests/golden.rs`, `cache_key.rs`) are
    unchanged by 123 to 126: no shipped program the tables pin uses the new names or an untyped
    operand, and the reflection keys are written only when they say something. The current
    translator changes use revision 3 (note 131).

128. **`GLSL` is undefined** (Wallpaper Engine reference probe T5).
    The reference prelude defines only `HLSL` and `HLSL_SM40`. The shipped `#if GLSL` blocks are the
    `discard` below half alpha inside `#if ALPHATOCOVERAGE` (`clippingmaskimage4.frag`,
    `generic3.frag`, `generic4.frag`, `genericimage3.frag`, `genericimage4.frag`,
    `genericparticle.frag`, `genericropeparticle.frag`, `shadowcaster.frag`,
    `shadowcasterfoliage4.frag`, `base/model_fragment_v1.h`), now not taken, so coverage decides
    what is kept, and `puppettexturechannels.vert`'s `#ifdef GLSL` index, whose Direct3D form
    `g_BlendMap[a_BlendIndices.x / 4.0][mod(a_BlendIndices.x, 4.0)]` is taken (float subscripts
    convert to `int`, R39, the same values for the non-negative indices it gets). The local
    workshop library (20 wallpapers, packaged and loose shaders) names `GLSL` only in a comment of
    the eight copies of `Simple_Audio_Bars.frag` ("Same as GLSL's modulo function"). The shipped
    sweeps compile the same counts with and without the define (167 legalized and compiled, 161 of
    162 end to end). Revision 5 also preserves the authored alpha sharpening instead of
    replacing it with the source alpha (note 137).

129. **GLSL-only calls are refused.** Wallpaper Engine 2.8.0.42's HLSL prelude has no mapping
    for `fract`, `inversesqrt`, two-argument `atan`, GLSL derivative spellings, matrix `inverse`,
    component comparisons, bit reinterpretation/scan names, and the other entries in
    `WE_REFUSED_GLSL_CALLS`. The stage uses its normal compiler-failure fallback, including when
    the bad call is in an unused function. Reference probes T6/T13 distinguish those refusals
    from the accepted HLSL controls. A function the author declares under one of those names
    is called with the ordinary HLSL argument conversions, including scalar broadcasts and
    vector truncation; it cannot accidentally resolve to the GLSL builtin instead.
    `ConvertOptions::glsl_builtins` is only for reconverting our already-generated GLSL,
    whose dialect operations use those GLSL names internally; the authored pipeline leaves it off.
130. **HLSL bit operations keep their types.** `rsqrt`, `asuint`, `asint`, `asfloat`,
    `countbits`, `firstbithigh` and `firstbitlow` lower to their GLSL operations while preserving
    scalar/vector width and component kind. Unsigned scans explicitly convert the GLSL signed
    result back to unsigned, so a zero input yields `0xffffffff` before subsequent arithmetic
    or a float conversion. This follows the [HLSL firstbithigh overloads](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/firstbithigh)
    and [firstbitlow contract](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/firstbitlow),
    and GPU tests check the actual values, including unsigned comparisons against negative integers.
131. **Pipeline revision 3.** The compiler identity and cache keys now include revision 3;
    older rows in the dialect, Metal and cache-key golden tables remain unchanged. The dialect
    digest uses `transpose` in the fixture that formerly called the now-invalid builtin `inverse`.
    Texture-format/reflection changes, the absent `GLSL` define, and these call rules therefore
    cannot reuse programs built under revision 2.
132. **Material-property metadata.** A uniform alias whose annotation has
    `"conversion":"rad2deg"` carries `"rad2deg":true`. False flags are absent from JSON. The C++ bridge treats absent fields as
    false, keeps the last duplicate alias's flags with its uniform, and passes them through
    `WPShaderInfo` as `alias_rad2deg`. Revision 3 also prevents old metadata without this
    flag being reused.

133. **T13 sampling vocabulary.** Authored `texture`, `texture2D`, `tex2D`, `textureLod`,
    `texture2DLod`, `tex2DLod`, `texelFetch` and `textureSize` calls fail as in WE 2.8.0.42.
    T13's follow-up distinguishes the dialect controls: `texSample2D` takes two arguments,
    `texSample2DLod` three. Wrong counts fail instead of acquiring GLSL's optional bias.
    Author-declared functions under the refused names retain their ordinary signatures.
    Engine/test source inputs use `texSample*` or `texLoad2D`; generated GLSL still uses
    `texture*`/`texelFetch` and reconverts with `glsl_builtins` enabled.
134. **Type spellings depend on their position.** Measured local/uniform/function probes
    reject `ivec2`, `ivec3`, `uvec2`, `uvec3` and `bvec2/3/4`. `ivec4` is accepted as a
    uniform but not a local type; `uvec4` is accepted in uniforms, locals, functions and
    constructors. Native HLSL `int2/3/4`, `uint2/3/4` and `bool2/3/4` are accepted. Their
    spellings survive author validation before being emitted as canonical GLSL types,
    so legal `int2` is not mistaken for authored `ivec2`. Internal generated types remain valid.
135. **`modf` output arguments.** A generated helper truncates each floating component,
    writes the integral part and returns `x - whole`. A scalar input broadcasts to a
    vector output; an input vector cannot narrow into a smaller output. Scalar/vector
    `int`, `uint` and `bool` outputs convert the whole part after computing the fraction
    from its floating value. Floating matrices are processed by columns. WE accepts a
    swizzle output and rejects duplicate swizzles, non-lvalues and wrong argument counts;
    an author's matching `modf` definition takes precedence. Naga's GLSL front end lacks
    this intrinsic and evaluates a helper's indexed out argument twice, so this lowering
    captures the input and output indices in call-local temporaries before invoking it.
    GPU tests pin single evaluation, integer/boolean outputs and matrix results.
    Runtime texture probes show `modf(-0)` returning +0 with whole -0, +infinity producing
    a NaN fraction with infinite whole, and NaN producing two NaNs. Constant-expression
    probes differ for signed zero; this work pins runtime behavior, not every optimizer
    folding choice or the separate hex-literal syntax gap.
136. **Pipeline revision 4.** The type/call refusals and `modf` output change are identified
    by revision 4. New cache-key, converted-text and MSL rows are appended; rows 1–3 are
    retained byte-for-byte. The fixed converted/MSL examples keep their previous digests,
    while the identity-dependent program key changes.

137. **MSAA preserves alpha sharpening; pipeline revision 5.** Wallpaper Engine 2.8.0.42
    at 4x gives raw alpha 0.25/0.75 one-quarter and three-quarter coverage. With its stock
    `saturate((alpha - 0.5) / max(fwidth(alpha), 0.0001) + 0.5)` formula, those constant
    values give zero and full coverage. The legacy R83 replacement therefore changed
    visible pixels. The formula, its derivative and any nested texture read now remain
    intact through dialect conversion and legalization. One-sample controls at 0.25 and
    0.75 retain their rejected/covered results; the exact 0.5 threshold is not established
    by that reference. The renderer uses A2C without also blending by the same alpha.
    Revision 5 appends cache-key, converted-text and MSL rows without altering rows 1–4.
    The fixed converted/MSL examples keep their digests, and the identity-dependent key changes.

138. **Resolved back-buffer slots; pipeline revision 6.** A texture record can include
    `sample_count` (1, 2, 4 or 8). Omitted preserves the existing declaration rules.
    With `BACKBUFFER_MS=1`, a declared back buffer whose bound image has one physical
    sample is emitted as a Metal 2D image, and its integer sample-zero read becomes
    a mip-zero texel read. It stays unfiltered; the macro value remains available to
    the author's conditionals. Other slots keep real multisample declarations and
    sample-zero reads, including in the same program and through sampler helpers.
    WE 2.8.0.42's cold-start model probe reports `Texture2DMS` with one sample for
    `_rt_FullFrameBuffer` during 4x scene drawing: its ordinary reader and back-buffer
    reader see the resolved colors. The internal `_rt_FullFrameBufferMultiSampled`
    name is not exposed to that author texture lookup. This does not replace true
    MS resources with a filtered resolved sample. Physical sample counts enter the
    cache key when present, and revision 6 appends the three golden rows while
    retaining revisions 1–5.

`alpha_sharpening_compiles_with_the_system_metal_compiler` checks the preserved formula
with the system compiler (`WM_SHADER_METAL_COMPILE=1`); the Engine MSAA pixel regression
checks raw/sharpened coverage at 1x and 4x.

`tests/we_parity_calls.rs` covers the observed T13/follow-up boundaries and the physical
Metal output-argument checks (`WM_SHADER_GPU_PROBES=1`).
`modf_output_conversions_compile_with_the_system_metal_compiler` exercises the actual render
stages with the system compiler (`WM_SHADER_METAL_COMPILE=1`). These changes do not claim
complete coverage of all remaining builtin names, constructor syntax or builtin uniforms.

139. **Authored expression shapes; pipeline revision 8.** The 24-cell WE 2.8.0.42
    probe rejects matrix/vector `*` in either order with X3020, including a bare
    expression and results assigned to vectors or matrices. Matrix/matrix and
    matrix/scalar products remain accepted. Author validation requires `mul` for
    the rejected forms; its lowered GLSL matrix operators remain valid.
    Float-vector constructors consume exactly their component count: WE rejects
    `vec2(gray)`, `vec3(gray)`, `vec4(gray)` and `vec3(vec4(...))` with X3014, while
    same-width copies and explicit component lists compile. `CAST3(gray)`,
    `(vec3)gray` and `(float3)gray` broadcast the scalar. The parser preserves the
    distinction between a cast and a constructor until conversion; internal
    constructors and reconverted generated GLSL retain GLSL's broadcast and
    truncation rules. Engine-owned shader source and test source use explicit
    casts or `mul`. `tests/we_parity_shapes.rs` pins the rejection and positive
    controls independently of shader names. Revision 8 appends cache-key,
    converted-text and MSL rows without changing rows 1–7; fixed converted/MSL
    digests remain unchanged after migrating their authored input syntax.
140. **Coverage facts; pipeline revision 9.** The reflection document gains two keys,
    written only when they hold so an older or newer reader takes their absence as "not
    proven": `"vertex_position":{"input":…,"matrix":…}` and `"fragment_always_writes":true`
    (`src/reflect/coverage.rs`). The engine opens a render pass with a clear instead of a
    load when one draw provably writes every texel of its target, and these are the
    shader half of that proof. The fragment fact: no `Kill` anywhere in the module, no
    sample-mask output and a float `vec4` at location 0. The vertex fact: the entry point
    returns its position from one top-level `return`, and that value is
    `vec4(input.xyz, 1.0)` or a `mat4` uniform block member times it (matrix on the left, as
    `mul(vec4(…), m)` lowers), followed through private and local variables that have
    exactly one write, a whole store at the top level of its function, reached (no
    `return`/`discard` before it) and ordered before the load: in the same function by
    statement index, across the entry point and `main` through their single call site.
    Any other statement kind in the module, any second or nested write, a pointer passed to
    a call, a clip or cull distance output, or a component that is not the input's x, y, z
    and the constant 1 leaves the fact out. Shipped effects: waterwaves, tint, spin (its
    copy of `a_Position`), blur's gaussian kernels in every `#if` and skew, transform and
    foliagesway in `MODE` 0 are proven; the last three in `MODE` 1 move the corners and are
    not. Revision 9 appends cache-key, converted-text and MSL rows with the MSL and
    converted digests unchanged; the parity goldens gained the two keys and nothing else.
141. **Read uniforms; pipeline revision 10.** The reflection document gains
    `"read_uniforms":[…]`, the names of the uniform block members anything the program
    produces can depend on, ascending, written only when every stage answered so a reader
    takes its absence as "every declared member is read" (`src/reflect/reads.rs`). A
    declaration, and even a name in the translated text, is not a read: Wallpaper Engine's
    `genericimage4.vert` forms `g_EyePosition - worldPos` in every variant and uses it only
    when lit or fogged. The engine leaves a layer's world transform and the active camera out
    of a reuse sample when no read uniform derives from them. The analysis is a backward
    liveness over the module that is translated: the entry point's returned value and every
    `If`, `Switch` and `break_if` condition of a reached function are used; a used expression
    uses its operands; a used load of a variable (local, private, or a parameter) uses every
    store into it in any reached function, its initializer and the stored element's indices;
    a used `CallResult` uses the callee's returned values; a used parameter uses the argument
    at every call; a pointer argument joins the caller's variable and the parameter both
    ways; a member is read when a used `AccessIndex` selects it from a `Uniform` global, every
    member when the global is used otherwise. It iterates to a fixed point and only ever
    over-states the reads. Atomics, image stores, workgroup loads, subgroup, ray-query and
    cooperative forms, or a store through a pointer not rooted in a variable or parameter,
    leave the key out. Every shipped program of the sweep answers (161, 243 declared members
    unread). Revision 10 appends cache-key, converted-text and MSL rows with the MSL and
    converted digests unchanged; the parity goldens gained the key and nothing else.
142. **Fragment colour; pipeline revision 10.** The reflection document gains
    `"fragment_colour"`, an array of four channels (red, green, blue, alpha), each `null` or
    the factors whose product the channel is: `{"uniform":member,"component":k}` for a
    32-bit float uniform block member (a scalar's component is 0) and
    `{"constant_bits":bits}` for a float constant, its bits so NaN and infinity survive. It
    is written only when the alpha channel is proven. The analysis (`Prover::colour` in
    `src/reflect/coverage.rs`) starts at the location-0 output of the entry point's single
    final `return` (no dual-source output) and follows compositions, splats, swizzles,
    component accesses, `*` of scalars and vectors channel by channel, float literals and
    constants, loads of uniform block members (whole or one component) and the same
    once-written private and local variables as the vertex fact; it needs the validated
    module's expression types for the channel counts. Anything else (a texture sample, a
    varying, a sum, a function call, a matrix, an array element, a second write) leaves that
    channel `null`. The engine leaves out a draw whose frame's uniforms make the alpha 0 and
    every factor finite, under a blend that keeps the destination at alpha 0. Wallpaper
    Engine's `flat.frag` (the solid layer) without `VERTEXCOLOR` is proven. It shares
    revision 10 with note 141.
143. **One retry with `GLSL` for a program over the component budget** (issue #161). When
    legalization refuses a program only because its fragment varyings exceed 124 components
    (`LegalizeError::ComponentBudget`, note 110), `pipeline::prepare_and_legalize` prepares it
    once more with `Prelude::Direct3DWithGlsl` (`HLSL`, `HLSL_SM40` and `GLSL` all 1) and
    legalizes that. Workshop effects such as the audio oscilloscopes declare
    `varying vec4 audioValue[RESOLUTION]` for Windows and a smaller array behind `#ifdef GLSL`
    for tighter interpolator limits (`vec4[28]` at the default `RESOLUTION` 32: 120 components
    where the Direct3D branch has 136). Wallpaper Engine's compiler gets under its own limit by
    removing the unused array elements, which this layer does not do. A program that passes
    the first time never sees `GLSL`, so note 128 holds for every program that already
    compiled and their Metal text and cache keys are unchanged, with no revision bump. A refused
    program was never stored. When the retry changes no stage text, fails to preprocess or is
    still refused, the first refusal stands (`vec4[60]` at `RESOLUTION` 64 is still 248). The
    retried program takes every `#if GLSL` branch, including the alpha-to-coverage `discard`
    of note 128; that only matters for a program that could not compile otherwise. Tests:
    `pipeline::tests::budget` (`a_program_over_the_budget_is_compiled_again_with_glsl_defined`,
    `a_program_within_the_budget_never_sees_glsl`,
    `a_program_still_over_the_budget_with_glsl_keeps_the_first_refusal`) and `preprocess`
    `the_glsl_prelude_adds_glsl_to_the_direct3d_macros_without_writing_any`.

The shipped sweeps now include `volumetricsfront` (167 programs legalized and compiled, 1 failing
as before: `shadowcasterfoliage4`'s undeclared `g_Texture1Texel`); every `SHADOW`, `POINTLIGHT`
and `BACKBUFFER_MS` combination of it compiles (`pins`).

## Point geometry stages (WE's DX11 rope path)

A request may carry `point_geometry` (`source`, `max_vertices`, `output_index_attribute`):
an author geometry program with one point input (`IN[0]`) and a triangle-strip output
(`OUT.Append`). `prepare` preprocesses it with the vertex stage's combos, and
`point_geometry::lower` folds it into the vertex stage. The author's vertex `main` runs
first and fills the input record. Then the geometry `main` runs, and its append keeps
only the vertex whose ordinal is `int(<output_index_attribute>.x)`. Its outputs become
the varyings the fragment stage reads. The caller draws `max_vertices` copies of each point,
each naming its ordinal; the declared `maxvertexcount` must equal `max_vertices` after
preprocessing, or the request is refused. Geometry-private globals and helpers get
stage-private names, and a uniform both stages declare must have one type. The
lowered program is ordinary vertex text from there on, so dialect rules (scalar
swizzles and the rest) still apply to the author's geometry code. The geometry source
and bounds are part of the cache key.

Every invocation runs the whole geometry program to keep one vertex, so a strip of
`n` vertices costs about `n` times one geometry run. The renderer uses it only for rope
materials with a `.geom`: one record per pair, `4 + 2 * TRAILSUBDIVISION` invocations,
as WE writes them (0x1402308A0). An offscreen probe of eight 1000-particle ropes at
subdivision 32 (68 invocations per pair) took 2.94-3.04 s for 300 frames against
2.99-3.08 s on the vertex-only path: no difference beyond run-to-run noise.
`tests/point_geometry.rs` pins the contract; `metal_compile.rs` translates the shipped
`genericropeparticle` with its geometry stage for 384 renderer combinations.

## Measurements (step 3)

Release build, converting the preprocessed stages of the shipped shaders under three combo sets
(318 stages) and of the local workshop library (1,677 stages): median 32 µs and worst 0.9 ms per
stage for the shipped ones, median 74 µs and worst 0.7 ms for the workshop ones. Every shipped
stage converts and compiles to Metal through naga (with the test-only layout stand-in), converting
the output again gives the same text for all of them, and 1,653 of 1,680 workshop stages
compile; the 27 that do not are named in `workshop_shaders_convert_and_compile_through_naga`
(an undeclared varying, a declaration that is not GLSL, the varying-width and widened-array
cases that belong to the interface and resource parts, and a `#if` the preprocessor refuses).
Mutation fuzzing of the shipped shaders (600,000 edited stages, release) and random token soup
(300,000 stages) produced no panic.
