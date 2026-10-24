// A synthetic scene loaded for its runtime only: no renderer, no Metal device, no window.
//
// `ScriptScene` parses a `ScenePackage` the way the host does and then lets a test advance the
// scene runtime (property scripts, bindings, animations) frame by frame and look at what the
// scripts did to the layers, the shader constants and the effects. It is the CPU companion of
// `GpuScene` (gpu_scene.hpp) for behaviour that has nothing to draw.
#pragma once

#include "support/scene_package.hpp"

#include <array>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace wallpaper
{
class Scene;
class SceneRuntimeContext;
} // namespace wallpaper

namespace we_test
{

struct ScriptSceneOptions {
    /// Seconds each tick advances the runtime clock.
    double time_step { 1.0 / 60.0 };
    /// The user's saved property values, as the host passes them on load.
    Json saved_properties { Json::object() };
};

class ScriptScene {
public:
    explicit ScriptScene(const ScenePackage& package, ScriptSceneOptions options = {});
    ~ScriptScene();
    ScriptScene(const ScriptScene&)            = delete;
    ScriptScene& operator=(const ScriptScene&) = delete;

    [[nodiscard]] bool               ok() const;
    [[nodiscard]] const std::string& error() const;

    /// Runs the runtime for `frames` ticks, the way a frame of the host does (without drawing).
    void Tick(int frames = 1);
    /// Shows a user property with a new value, as the host's live preview does. Values set
    /// earlier stay set.
    bool SetProperty(const std::string& name, const Json& value);

    [[nodiscard]] wallpaper::Scene&               scene();
    [[nodiscard]] wallpaper::SceneRuntimeContext& runtime();

    // ---- what the scripts did ----------------------------------------------------------
    [[nodiscard]] std::array<float, 3> Origin(const std::string& layer);
    [[nodiscard]] std::array<float, 3> Scale(const std::string& layer);
    /// The layer's angles in degrees, as scripts read them.
    [[nodiscard]] std::array<float, 3> AnglesDegrees(const std::string& layer);
    [[nodiscard]] std::array<float, 3> Color(const std::string& layer);
    [[nodiscard]] std::array<float, 2> ParallaxDepth(const std::string& layer);
    [[nodiscard]] bool                 Visible(const std::string& layer);
    /// Script errors the runtime recorded (empty when every script ran cleanly).
    [[nodiscard]] std::vector<std::string> ScriptErrors();

    // ---- effects -----------------------------------------------------------------------
    /// The `visible` flag of every effect of every effect chain, in chain order.
    [[nodiscard]] std::vector<bool> EffectVisibility();
    /// The lanes of shader constant `uniform` in the first pass of effect `effect` of the first
    /// chain that has one; empty when there is none.
    [[nodiscard]] std::vector<float> EffectConstant(std::size_t effect, const std::string& uniform);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

/// A minimal WAV file (mono, 16 bit, 8 kHz) for sound objects.
std::string MakeWav(double seconds = 0.25);

} // namespace we_test
