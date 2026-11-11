#pragma once

#include "MetalRender/SceneMetalProgram.hpp"

#include <memory>
#include <string_view>

namespace wallpaper::shader
{

struct RustShaderMetalStage;

/// Wallpaper Engine's shader of last resort, `shaders/HLSL/dx11fallback.vert` / `.frag`, in our
/// dialect (the shipped files are raw HLSL with cbuffers). When a stage of a pass does not
/// compile, Wallpaper Engine 2.8.0.42 compiles this stage in its place and draws the pass with
/// everything else it has: its blending, depth and cull state (`sub_1400D5070`; probe T9:
/// dark red (0.5, 0, 0, 1), blended as the pass says).
inline constexpr std::string_view kFallbackVertexSource =
    "uniform mat4 g_ModelViewProjectionMatrix;\n"
    "attribute vec3 a_Position;\n"
    "void main() {\n"
    "\tgl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);\n"
    "}\n";
inline constexpr std::string_view kFallbackFragmentSource =
    "void main() {\n"
    "\tgl_FragColor = vec4(0.5, 0.0, 0.0, 1.0);\n"
    "}\n";

/// One translated stage as the renderer holds it.
SceneMetalStage ToSceneMetalStage(const RustShaderMetalStage& stage);

/// The fallback pair translated once per process, for a pass whose own translated program the
/// Metal compiler refuses. Null only if the translator itself is broken.
std::shared_ptr<const SceneMetalProgram> FallbackMetalProgram();

} // namespace wallpaper::shader
