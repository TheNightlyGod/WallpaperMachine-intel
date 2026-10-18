#pragma once

#include <Eigen/Core>

namespace wallpaper
{

/// How many times the size a particle holds here is Wallpaper Engine's own for
/// the same particle: the renderer draws half of `size`, so a size initializer's
/// draw lands in the engine's array as half of it. A size taken from, or
/// compared with, another particle's engine size is in this unit's half.
inline constexpr float kParticleSizeOverEngine = 2.0f;

/// What a particle is before its initializers run. Wallpaper Engine's size and
/// alpha initializers (`sizerandom`, `alpharandom`) scale the value the particle
/// has so far, as its colour initializers do, so a file may stack them; they
/// start from the particle's own size (0.5 there) and alpha (1). The size here
/// starts at the engine's 0.5 in this unit, which is 1.
inline constexpr float kParticleStartSize  = 0.5f * kParticleSizeOverEngine;
inline constexpr float kParticleStartAlpha = 1.0f;

struct Particle {
    struct InitValue {
        Eigen::Vector3f color { 1.0f, 1.0f, 1.0f };
        float           alpha { kParticleStartAlpha };
        float           size { kParticleStartSize };
        float           lifetime { 1.0f };
        /// Fixed per particle, in [0, 1). Picks a `randomframe` sprite.
        float           frame { 0.0f };
    };
    Eigen::Vector3f position { 0.0f, 0.0f, 0.0f };
    Eigen::Vector3f color { 1.0f, 1.0f, 1.0f };
    float           alpha { kParticleStartAlpha };
    float           size { kParticleStartSize };
    float           lifetime { 1.0f };

    Eigen::Vector3f rotation { 0.0f, 0.0f, 0.0f }; // radian  z x y
    Eigen::Vector3f velocity { 0.0f, 0.0f, 0.0f };
    Eigen::Vector3f acceleration { 0.0f, 0.0f, 0.0f };
    Eigen::Vector3f angularVelocity { 0.0f, 0.0f, 0.0f };
    Eigen::Vector3f angularAcceleration { 0.0f, 0.0f, 0.0f };

    /// Fixed per particle, in [0, 1). One draw at spawn that every operator
    /// reading "this particle's random" shares (oscillators, turbulence),
    /// as Wallpaper Engine keeps one per particle.
    float     seed { 0.0f };

    /// Where the movement operator found the particle at the start of its
    /// last step, kept only while an operator asks for it (a control point
    /// attraction that removes particles it passes). Equal to the spawn
    /// position until the first step.
    Eigen::Vector3f prev_position { 0.0f, 0.0f, 0.0f };

    bool      mark_new { true };
    InitValue init {};
};
} // namespace wallpaper
