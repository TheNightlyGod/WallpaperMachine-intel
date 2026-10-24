#pragma once

#include <cstdint>
#include <string>

namespace wallpaper
{

/// What stopped a scene from being drawn.
///
/// Native Metal is the only renderer there is. A scene it cannot draw is not
/// handed to another one: the surface keeps its last picture (or shows the
/// project's still preview when it has drawn nothing), and the failure and its
/// reason are reported.
///
/// A category, never the whole explanation: the host words each one for the
/// user in their language and shows the engine's own `failure_reason` beside it.
enum class SceneFailureStage : uint8_t
{
    None = 0,
    /// The scene uses something the native backend does not support, found
    /// before any renderer was created: a refused admission.
    Unsupported = 1,
    /// The native renderer could not be created on the surface.
    Prepare = 2,
    /// The scene's shaders or pipelines did not compile for Metal.
    Compile = 3,
    /// A frame failed after the scene had been set up.
    Frame = 4,
    /// The surface could not be re-established after a display change.
    Surface = 5,
};

/// Stable lowercase name for logs and the bridge.
[[nodiscard]] constexpr const char* ToString(SceneFailureStage stage)
{
    switch (stage) {
    case SceneFailureStage::None: return "";
    case SceneFailureStage::Unsupported: return "unsupported";
    case SceneFailureStage::Prepare: return "prepare";
    case SceneFailureStage::Compile: return "compile";
    case SceneFailureStage::Frame: return "frame";
    case SceneFailureStage::Surface: return "surface";
    }
    return "";
}

/// Whether a scene can be drawn, and when not, why.
///
/// A failure always carries a specific, user-readable reason: "unsupported"
/// with no reason is indistinguishable from a bug, and this is the string a
/// user will quote when asking why their wallpaper does not play.
struct SceneBackendSelection
{
    /// False while this is still only a decision, true once a renderer has
    /// actually been created for it (or the scene has been held). A surface
    /// whose scene has not been parsed yet has no renderer at all, and
    /// reporting one as if it existed would name a renderer that is not
    /// drawing.
    bool created { false };

    /// Set when the scene is not being drawn.
    SceneFailureStage failure_stage { SceneFailureStage::None };
    std::string       failure_reason;

    [[nodiscard]] bool failed() const { return failure_stage != SceneFailureStage::None; }
};

} // namespace wallpaper
