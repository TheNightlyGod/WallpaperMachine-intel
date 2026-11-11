#pragma once
// `remapvalue` (operator) and `remapinitialvalue` (initializer) of Wallpaper
// Engine 2.8.0.42's particle system, read off the decompile
// (artifacts/we-parity/decompiles/F-D11.md): a particle or system quantity is
// normalised by an input range, passed through a transform, scaled into an
// output range and combined into another quantity.

#include "Particle/Particle.h"
#include "Particle/ParticleEmitter.h"
#include "Utils/Linalg.hpp"

#include <nlohmann/json.hpp>

#include <span>

namespace wallpaper::ParticleRemap
{

/// The quantity table both `input` and `output` index (off_140484E80).
enum class Quantity : int
{
    LifetimeFraction = 0,
    MaxLifetime,
    Size,
    Opacity,
    Speed,
    Rotation,
    AngularSpeed,
    DistanceToControlPoint,
    PositionBetweenTwoControlPoints,
    Runtime,
    TimeOfDay,
    ParticleSystemTime,
    LayerTime,
    Color,
    Position,
    Velocity,
    ControlPoint,
    DeltaToControlPoint,
    DirectionToControlPoint,
    LayerOrigin,
    Unknown = 21,
};

struct Config {
    /// remap 0, multiply 1, add 2, subtract 3; anything else writes nothing.
    int      operation { 1 };
    Quantity input { Quantity::LifetimeFraction };
    Quantity output { Quantity::Size };
    /// all 0, x 1, y 2, z 3, sum 4, average 5, max 6, min 7.
    int input_component { 0 };
    int output_component { 0 };
    /// none 0, sine 1, square 2, saw 3, triangle 4, simplexnoise 5, fbmnoise 6.
    int transform { 0 };
    /// 1 clamps the normalised input to 0..1, 2 the output value.
    int              flags { 1 };
    linalg::Vector3d input_min { 0, 0, 0 };
    linalg::Vector3d input_range { 1, 1, 1 };
    linalg::Vector3d output_min { 0, 0, 0 };
    linalg::Vector3d output_range { 1, 1, 1 };
    int              input_point0 { 0 }, input_point1 { 1 };
    int              output_point0 { 0 }, output_point1 { 1 };
    double           input_scale { 1.0 };
    int              octaves { 3 };
};

/// The record's keys with the engine's defaults (sub_1401BFBB0).
Config Read(const nlohmann::json& record);

/// What an evaluation reads besides the particle.
struct Frame {
    std::span<const ParticleControlpoint> controlpoints;
    /// The engine time `runtime` and `particlesystemtime` read.
    bool             world_space { false };
    double           system_time { 0.0 };
    double           layer_time { 0.0 };
    double           time_of_day { 0.0 };
    linalg::Vector3d layer_origin { 0.0, 0.0, 0.0 };
};

/// Reads the input, maps it and writes the output of one particle. `birth`
/// (the initializer) writes the birth values a particle restarts from each
/// step as well; its noise transform is the engine's 1D simplex.
void Apply(const Config& config, Particle& particle, const Frame& frame, bool birth,
           ParticleControlpoint* destination = nullptr);

/// Whether the record's input needs the layer origin or the time of day.
bool ReadsLayerOrigin(const nlohmann::json& record);
bool ReadsTimeOfDay(const nlohmann::json& record);

} // namespace wallpaper::ParticleRemap
