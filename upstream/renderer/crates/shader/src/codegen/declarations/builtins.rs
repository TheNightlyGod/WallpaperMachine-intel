//! Builtin variables a stage reads without declaring them.

/// OpenGL builtin variables mapped to the Vulkan spelling Naga's GLSL
/// frontend reads.
///
/// Wallpaper Engine's shaders use the OpenGL names (`gl_VertexID`,
/// `gl_InstanceID`) as `uint`. Naga types its own `gl_VertexIndex` and
/// `gl_InstanceIndex` as `uint` too, so a use such as `gl_VertexID + offset`
/// or `CASTF(gl_InstanceID)` needs no conversion of its own.
pub(crate) const VULKAN_SPELLING: [(&str, &str); 2] = [
    ("gl_VertexID", "gl_VertexIndex"),
    ("gl_InstanceID", "gl_InstanceIndex"),
];

/// Vertex and fragment builtin variables Naga's GLSL frontend provides, under
/// the spelling it reads, and that a stage still compiles with once their
/// redeclaration is gone. `gl_ClipDistance`, `gl_CullDistance`, `gl_DrawID`
/// and `gl_PrimitiveID` are recognised but do not compile as builtins, so a
/// declaration of one stays what it was.
const PROVIDED: [&str; 11] = [
    "gl_Position",
    "gl_PointSize",
    "gl_VertexIndex",
    "gl_InstanceIndex",
    "gl_BaseVertex",
    "gl_BaseInstance",
    "gl_FragCoord",
    "gl_FrontFacing",
    "gl_PointCoord",
    "gl_FragDepth",
    "gl_SampleID",
];

/// Returns whether a stage-qualified declaration of `name` with type `ty`
/// restates a builtin and can be dropped.
///
/// A name with the `gl_` prefix is reserved, so a stage-qualified declaration
/// of one the backend provides (`in uint gl_VertexID;`, written for the
/// Direct3D dialect) can only restate the builtin. The builtins GLSL has
/// beyond these, such as `gl_ViewportIndex`, have no counterpart in the
/// backend to restate.
///
/// The OpenGL-spelled indices are restated only as Wallpaper Engine writes
/// them, `uint`: the backend's builtin is `uint`, so a declaration of another
/// type is the author's own variable and stays.
pub(crate) fn is_restated(name: &str, ty: &str) -> bool {
    if VULKAN_SPELLING.iter().any(|(opengl, _vulkan)| *opengl == name) {
        return ty == "uint";
    }
    PROVIDED.contains(&name)
}
