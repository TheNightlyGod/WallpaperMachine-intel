#pragma once

#include <array>
#include <cstddef>
#include <memory>
#include <string>
#include <vector>

namespace wallpaper
{
struct ScalarAnimationHandle
{
    double x { 0.0 };
    double y { 0.0 };
    bool enabled { false };
};


struct ScalarAnimationKeyframe
{
    double frame { 0.0 };
    float  value { 0.0f };
    ScalarAnimationHandle back;
    ScalarAnimationHandle front;
};

enum class ScalarAnimationMode
{
    Single,
    Loop,
};

// An authored timeline can carry named events. They belong to the timeline, not
// to a curve, so a group driven by one clock reports each of them once.
struct ScalarAnimationEvent
{
    double      frame { 0.0 };
    std::string name;
};

struct ScalarAnimation
{
    float                               initial_value { 0.0f };
    double                              fps { 0.0 };
    double                              length_frames { 0.0 };
    ScalarAnimationMode                 mode { ScalarAnimationMode::Single };
    std::string                         name;
    bool                                start_paused { false };
    std::vector<ScalarAnimationKeyframe> keyframes;
    std::vector<ScalarAnimationEvent>    events;

    [[nodiscard]] float Evaluate(double seconds) const;
    [[nodiscard]] double FrameCount() const;
};

struct ScalarAnimationPlayback
{
    ScalarAnimation animation;
    double frame { 0.0 };
    double rate { 1.0 };
    bool playing { false };
    // Markers crossed by the last Advance, in the order the playhead met them.
    // The runtime drains them each tick. A seek is an explicit jump, not
    // playback, so it reports nothing.
    std::vector<ScalarAnimationEvent> pending_events;

    void Advance(double seconds);
    void Play();
    void Stop();
    void SetFrame(double value);
    [[nodiscard]] float Value() const;
};

// A vec3 setting's three curves share one clock: a layer's origin, scale or
// angles, or an image layer's colour. Relative keys are offsets from the
// authored value, not from the previous sample. Settings the editor keyed
// together (`options.parent`) hold the same `playback`.
struct NodeVec3Animation
{
    std::shared_ptr<ScalarAnimationPlayback> playback;
    std::array<ScalarAnimation, 3>           components;
    std::array<float, 3>                     offset {};

    // The setting's value at the clock's current frame.
    [[nodiscard]] std::array<float, 3> Value() const;
};

// A vector shader constant animates one curve per component, and several
// constants may be driven by one authored timeline. The components keep their
// own curves and initial values while sharing that timeline's playback state.
struct MaterialConstantAnimation
{
    std::shared_ptr<ScalarAnimationPlayback> playback;
    std::array<ScalarAnimation, 4>           components;
    std::size_t                              component_count { 0 };
};

} // namespace wallpaper
