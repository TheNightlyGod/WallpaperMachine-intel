#pragma once

#include "Scene/SceneBackendSelection.hpp"

#include <string>

namespace wallpaper
{
class Scene;

namespace rg
{
class RenderGraph;
}

namespace metal
{

/// Structural reasons the native Metal backend cannot draw a scene, decided
/// from the parsed scene alone.
///
/// Empty means no structural reason was found. This deliberately does not look
/// at shader translation: it is also what the parser consults before spending a
/// second full shader compile on a scene that has already disqualified itself.
///
/// The boundary is what this renderer actually implements, not a list of
/// wallpaper identifiers. Anything it does not recognise is rejected rather
/// than approximated, because an approximation of an author's effect is a
/// wrong picture presented as a right one.
[[nodiscard]] std::string SceneMetalStructuralRejection(const Scene& scene);

/// Whole-scene capability gate. There is no per-layer mixing: a scene is drawn
/// entirely by Metal or it is not drawn.
///
/// Answers before anything is created. A scene Metal cannot draw comes back
/// failed (`SceneFailureStage::Unsupported`) with a short user-readable phrase
/// as the reason, because the settings pane shows the string verbatim; a scene
/// it can draw comes back with no failure.
[[nodiscard]] SceneBackendSelection EvaluateMetalSupport(const Scene& scene);

/// Pass kinds the Metal backend recognises in a compiled render graph.
///
/// `Unsupported` is the value every unrecognised graph node maps to, including
/// one added after this code was written. It is the default on purpose: a new
/// pass kind must make the scene fall back, never be silently skipped or drawn
/// as something else.
enum class MetalPassKind : uint8_t
{
    Unsupported = 0,
    /// An author material drawn with its own translated shader.
    CustomShader,
    /// A target-to-target copy.
    Copy,
    /// A clear of one target.
    Clear,
    /// A bookkeeping node that records a writer without producing pixels.
    Virtual,
};

/// Classifies one `rg::PassNode::Type`. Takes the raw enumerator value rather
/// than the enum so an out-of-range value -- which is what a future pass kind
/// looks like to this build -- can be classified at all.
[[nodiscard]] MetalPassKind ClassifyMetalPassKind(int pass_node_type);

/// Graph-level gate, run once the render graph exists. Rejects pass kinds this
/// backend does not recognise and feedback that survived the scene-level check.
///
/// Separate from `EvaluateMetalSupport` because the graph does not exist yet
/// when the backend is chosen; both must pass before a frame is drawn.
[[nodiscard]] std::string MetalGraphRejection(const Scene& scene, const rg::RenderGraph& graph);

} // namespace metal
} // namespace wallpaper
