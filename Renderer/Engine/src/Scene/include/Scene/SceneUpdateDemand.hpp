#pragma once

#include <chrono>
#include <cstdint>

namespace wallpaper
{

/// Why a scene still needs the frame clock to run.
///
/// Every reason is an independent bit, so a diagnostic can say which facility
/// kept a wallpaper awake rather than only that it did not sleep. The absence
/// of every bit is the only thing that permits idling, which makes an
/// unrecognised input fail safe: it either maps to `UnknownInput` or it is
/// carried by one of the specific bits, never by silence.
enum class SceneDemandReason : uint32_t
{
    None = 0,
    /// A SceneScript or a scripted property value runs on every tick.
    Script = 1u << 0,
    /// A scalar animation, a scene zoom animation or a material alpha
    /// animation is playing.
    Animation = 1u << 1,
    /// A particle emitter exists.
    Particles = 1u << 2,
    /// A video texture is being advanced.
    Video = 1u << 3,
    /// A shader consumes the audio spectrum.
    AudioResponse = 1u << 4,
    /// Reflection reported a uniform whose value advances every frame.
    TimeUniform = 1u << 5,
    /// A sprite sheet with more than one frame.
    AnimatedSprite = 1u << 6,
    /// Vertex or index data is re-uploaded per frame.
    DynamicMesh = 1u << 7,
    /// Puppet or skeletal transforms are written per frame.
    Puppet = 1u << 8,
    /// A pass reads a target it also writes, or the frame reads a target
    /// before writing it, so each frame's picture feeds the next.
    Feedback = 1u << 9,
    /// A text layer's content is produced from a bound value that re-evaluates
    /// on its own -- a script, which may be a clock or a date.
    TextBinding = 1u << 10,
    /// A sound layer exists. Image stillness says nothing about audio, and this
    /// analysis cannot yet prove a sound is independent of the tick.
    Sound = 1u << 11,
    /// A node's visibility, translation, scale or rotation is driven by a bound
    /// value rather than being fixed at parse time.
    NodeBinding = 1u << 12,
    /// An input this analysis cannot account for. Load-bearing: it is the
    /// difference between "proven still" and "not understood".
    UnknownInput = 1u << 13,
    /// No complete frame has been presented yet. Idling here would leave the
    /// surface showing whatever preceded the wallpaper.
    NoFrameYet = 1u << 14,
    /// A text layer's new layout is still being produced, or has been produced
    /// and not yet applied. Clears when the worker's result reaches a frame.
    TextLayoutPending = 1u << 15,
};

constexpr uint32_t operator|(SceneDemandReason lhs, SceneDemandReason rhs)
{
    return static_cast<uint32_t>(lhs) | static_cast<uint32_t>(rhs);
}

constexpr uint32_t operator|(uint32_t lhs, SceneDemandReason rhs)
{
    return lhs | static_cast<uint32_t>(rhs);
}

constexpr uint32_t& operator|=(uint32_t& lhs, SceneDemandReason rhs)
{
    lhs = lhs | static_cast<uint32_t>(rhs);
    return lhs;
}

constexpr bool operator&(uint32_t lhs, SceneDemandReason rhs)
{
    return (lhs & static_cast<uint32_t>(rhs)) != 0;
}

/// What the scene needs from the frame clock.
///
/// `Continuous` is the safe answer and the one every scene that cannot describe
/// itself produces. Nothing here decides whether the renderer may reuse pixels;
/// that is a separate question answered per render target. A scene whose
/// targets all hit the reuse cache may still need to keep ticking, because
/// scripts, sound and timelines run whether or not anything is redrawn.
struct SceneUpdateDemand
{
    enum class Kind : uint8_t
    {
        /// Keep the configured cadence.
        Continuous = 0,
        /// Stop the periodic clock; only an event starts it again.
        WaitingForEvent = 1,
        /// Stop the periodic clock until one known instant.
        WaitingForDeadline = 2,
    };

    Kind     kind { Kind::Continuous };
    uint32_t reasons { static_cast<uint32_t>(SceneDemandReason::UnknownInput) };
    /// Only meaningful for `WaitingForDeadline`.
    std::chrono::steady_clock::time_point deadline {};

    [[nodiscard]] bool Idle() const { return kind != Kind::Continuous; }
};

/// Process-wide switch for whole-scene on-demand updating.
///
/// Off by default: stopping a wallpaper's clock is a visible behaviour change,
/// so it is opted into rather than out of. Turning it off restores the fixed
/// cadence for every scene without reloading anything.
void SetSceneOnDemandEnabled(bool enabled);
bool SceneOnDemandEnabled();

/// Translates the renderer's per-pass dynamic-input vocabulary into scene-level
/// reasons. Declared here so the renderer, the scene and the tests share one
/// definition of which shader inputs mean "keep ticking".
uint32_t SceneDemandReasonsFromShaderInputs(uint32_t shader_reasons);

/// Whether any pass samples the pointer.
///
/// Kept separate from the demand reasons on purpose: a pointer-reactive
/// scene is event-driven, not continuously changing, so this decides whether
/// pointer events wake it rather than whether it may sleep at all.
bool SceneShaderInputsUsePointer(uint32_t shader_reasons);

} // namespace wallpaper
