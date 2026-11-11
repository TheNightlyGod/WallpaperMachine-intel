// Clean-room port of `remapvalue` / `remapinitialvalue` read off Wallpaper
// Engine 2.8.0.42's decompile; see WPParticleRemap.hpp and
// artifacts/we-parity/decompiles/F-D11.md.
#include "WPParticleRemap.hpp"

#include "Particle/ParticleModify.h"
#include "Particle/ParticleNoise.h"

#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <numbers>
#include <sstream>
#include <string_view>

namespace wallpaper::ParticleRemap
{
namespace
{

using Vec3d = linalg::Vector3d;
using Json  = nlohmann::json;
namespace PM = ParticleModify;

constexpr std::array<std::string_view, 20> kQuantityNames = {
    "lifetimefraction", "maxlifetime", "size", "opacity", "speed", "rotation", "angularspeed",
    "distancetocontrolpoint", "positionbetweentwocontrolpoints", "runtime", "timeofday",
    "particlesystemtime", "layertime", "color", "position", "velocity", "controlpoint",
    "deltatocontrolpoint", "directiontocontrolpoint", "layerorigin",
};

std::string Text(const Json& record, const char* key, const char* fallback) {
    const auto found = record.find(key);
    return found != record.end() && found->is_string() ? found->get<std::string>() : std::string(fallback);
}

int Integer(const Json& record, const char* key, int fallback) {
    const auto found = record.find(key);
    if (found == record.end() || ! found->is_number()) return fallback;
    return static_cast<int>(found->get<double>());
}

double Number(const Json& record, const char* key, double fallback) {
    const auto found = record.find(key);
    if (found == record.end() || ! found->is_number()) return fallback;
    const double v = found->get<double>();
    return std::isfinite(v) ? v : fallback;
}

/// A range key: a number fills all three lanes, a string gives up to three
/// numbers (missing ones 0), as the loader reads it.
Vec3d Range(const Json& record, const char* key, double fallback) {
    const auto found = record.find(key);
    if (found == record.end()) return Vec3d::Constant(fallback);
    if (found->is_number()) return Vec3d::Constant(found->get<double>());
    if (found->is_string()) {
        std::istringstream stream(found->get<std::string>());
        Vec3d              v = Vec3d::Zero();
        for (int i = 0; i < 3; ++i) {
            double value = 0.0;
            if (! (stream >> value)) break;
            v[i] = value;
        }
        return v;
    }
    return Vec3d::Constant(fallback);
}

Quantity QuantityOf(const std::string& name) {
    for (std::size_t i = 0; i < kQuantityNames.size(); ++i)
        if (kQuantityNames[i] == name) return static_cast<Quantity>(i);
    return Quantity::Unknown;
}

int IndexOf(const std::string& name, std::initializer_list<std::string_view> names, int other) {
    int i = 0;
    for (const auto n : names) {
        if (n == name) return i;
        ++i;
    }
    return other;
}

/// Control points 0..7; a number past the end names the last.
int Point(int index) { return std::clamp(index, 0, 7); }

Vec3d PointAt(const Frame& frame, int index) {
    const auto i = static_cast<std::size_t>(Point(index));
    return i < frame.controlpoints.size() ? frame.controlpoints[i].offset : Vec3d::Zero();
}

bool IsVector(Quantity q) { return static_cast<int>(q) >= static_cast<int>(Quantity::Color) &&
                                   static_cast<int>(q) <= static_cast<int>(Quantity::LayerOrigin); }

Vec3d Wide(const linalg::Vector3f& v) { return v.cast<double>(); }

Vec3d InputOf(const Config& c, const Particle& p, const Frame& frame) {
    const Vec3d pos = Wide(p.position);
    switch (c.input) {
    case Quantity::LifetimeFraction: return Vec3d::Constant(PM::LifetimePos(p));
    case Quantity::MaxLifetime: return Vec3d::Constant(p.init.lifetime);
    case Quantity::Size: return Vec3d::Constant(p.size / kParticleSizeOverEngine);
    case Quantity::Opacity: return Vec3d::Constant(p.alpha);
    case Quantity::Speed: return Vec3d::Constant(Wide(p.velocity).norm());
    case Quantity::Rotation: return Vec3d::Constant(p.rotation.z());
    case Quantity::AngularSpeed: return Vec3d::Constant(p.angularVelocity.z());
    case Quantity::DistanceToControlPoint:
        return Vec3d::Constant((pos - PointAt(frame, c.input_point0)).norm());
    case Quantity::PositionBetweenTwoControlPoints: {
        // The kernel takes the output points here (0x14023FBC0 case 8).
        const Vec3d  a = PointAt(frame, c.output_point0), b = PointAt(frame, c.output_point1);
        const double len2 = (b - a).squaredNorm();
        return Vec3d::Constant(len2 > 0.0 ? (pos - a).dot(b - a) / len2 : 0.0);
    }
    case Quantity::Runtime:
    case Quantity::ParticleSystemTime: return Vec3d::Constant(frame.system_time);
    case Quantity::TimeOfDay: return Vec3d::Constant(frame.time_of_day);
    case Quantity::LayerTime: return Vec3d::Constant(frame.layer_time);
    case Quantity::Color: return Wide(p.color);
    case Quantity::Position: return frame.world_space ? Vec3d(pos + frame.layer_origin) : pos;
    case Quantity::Velocity: return Wide(p.velocity);
    case Quantity::ControlPoint: return frame.world_space ? Vec3d(PointAt(frame, c.input_point0) + frame.layer_origin) : PointAt(frame, c.input_point0);
    case Quantity::DeltaToControlPoint: return PointAt(frame, c.input_point0) - pos;
    case Quantity::DirectionToControlPoint: {
        const Vec3d  d   = PointAt(frame, c.input_point0) - pos;
        const double len = d.norm();
        return len > 0.0 ? Vec3d(d / len) : Vec3d::Zero();
    }
    case Quantity::LayerOrigin: return frame.layer_origin;
    default: return Vec3d::Zero();
    }
}

Vec3d Reduce(const Vec3d& v, int component) {
    switch (component) {
    case 1: return Vec3d::Constant(v.x());
    case 2: return Vec3d::Constant(v.y());
    case 3: return Vec3d::Constant(v.z());
    case 4: return Vec3d::Constant(v.x() + v.y() + v.z());
    case 5: return Vec3d::Constant((v.x() + v.y() + v.z()) * 0.33333334);
    case 6: return Vec3d::Constant(std::max({ v.x(), v.y(), v.z() }));
    case 7: return Vec3d::Constant(std::min({ v.x(), v.y(), v.z() }));
    default: return v;
    }
}

double Trunc(double v) { return std::trunc(v); }

/// The lanes of one particle's noise transform: its random float's bits, the
/// y and z lanes XORed with the constants at 0x140492D40 / 0x140492F80.
constexpr std::array<std::uint32_t, 3> kLaneSeeds = { 0u, 0x0B3924ADu, 0x493A8E83u };

double Transform(const Config& c, double n, int lane, const Particle& p, bool birth) {
    const double s = c.input_scale;
    switch (c.transform) {
    case 1: return 0.5 + 0.5 * std::sin(std::numbers::pi * s * n - std::numbers::pi / 2.0);
    case 2: {
        const double x = s * n;
        return std::nearbyint(x - Trunc(x)) + (x < 0.0 ? 1.0 : 0.0);
    }
    case 3: {
        const double x = s * n;
        return x - Trunc(x) + (n < 0.0 ? 1.0 : 0.0);
    }
    case 4: {
        const double a = std::abs(s * n);
        return 1.0 - std::abs((a - Trunc(a)) * 2.0 - 1.0);
    }
    case 5:
    case 6: {
        const float x = static_cast<float>(s * n);
        if (birth) {
            // The initializer calls the engine's 1D simplex (sub_14027B090).
            return 0.5 + 0.5 * ParticleNoise::Simplex1(x);
        }
        const auto seed = static_cast<std::int32_t>(std::bit_cast<std::uint32_t>(p.seed) ^
                                                    kLaneSeeds[static_cast<std::size_t>(lane)]);
        const float noise = c.transform == 5 ? ParticleNoise::OpenSimplex2(seed, x, 0.0f)
                                             : ParticleNoise::OpenSimplex2Fbm(seed, x, 0.0f, c.octaves);
        return 0.5 + 0.5 * noise;
    }
    default: return n;
    }
}

double Combine(int operation, double current, double value) {
    switch (operation) {
    case 0: return value;
    case 1: return current * value;
    case 2: return current + value;
    case 3: return current - value;
    default: return current;
    }
}

Vec3d Combine(int operation, const Vec3d& current, const Vec3d& value) {
    return { Combine(operation, current.x(), value.x()), Combine(operation, current.y(), value.y()),
             Combine(operation, current.z(), value.z()) };
}

/// `current` with the lanes the output component names replaced.
Vec3d Lanes(int component, const Vec3d& current, const Vec3d& combined) {
    if (component < 1 || component > 3) return combined;
    Vec3d out                                     = current;
    out[component - 1] = combined[component - 1];
    return out;
}

linalg::Vector3f Narrow(const Vec3d& v) { return v.cast<float>(); }

void Write(const Config& c, Particle& p, const Vec3d& value, const Frame& frame, bool birth, ParticleControlpoint* destination) {
    const int    op = c.operation;
    const double x  = value.x();
    if ((op < 0 || op > 3) && c.output != Quantity::ControlPoint) return;
    switch (c.output) {
    case Quantity::MaxLifetime: {
        const double lifetime = std::max(Combine(op, p.init.lifetime, x), 0.001);
        if (birth) {
            PM::InitLifetime(p, static_cast<float>(lifetime));
        } else {
            const double age = PM::LifetimePassed(p);
            p.init.lifetime  = static_cast<float>(lifetime);
            p.lifetime       = static_cast<float>(lifetime - age);
        }
        return;
    }
    case Quantity::Size: {
        const double size = Combine(op, p.size / kParticleSizeOverEngine, x) * kParticleSizeOverEngine;
        if (birth) PM::InitSize(p, size);
        else p.size = static_cast<float>(size);
        return;
    }
    case Quantity::Opacity: {
        const double alpha = Combine(op, p.alpha, x);
        if (birth) PM::InitAlpha(p, alpha);
        else p.alpha = static_cast<float>(alpha);
        return;
    }
    case Quantity::Speed: {
        const Vec3d  v     = Wide(p.velocity);
        const double speed = v.norm();
        const double now   = Combine(op, speed, x);
        p.velocity         = Narrow(speed > 0.0 ? Vec3d(v * (now / speed)) : Vec3d(v * now));
        return;
    }
    case Quantity::Rotation: p.rotation.z() = static_cast<float>(Combine(op, p.rotation.z(), x)); return;
    case Quantity::AngularSpeed:
        p.angularVelocity.z() = static_cast<float>(Combine(op, p.angularVelocity.z(), x));
        return;
    case Quantity::DistanceToControlPoint: {
        const Vec3d  centre = PointAt(frame, c.output_point0);
        const Vec3d  d      = Wide(p.position) - centre;
        const double len    = d.norm();
        const Vec3d  dir    = len != 0.0 ? Vec3d(d / len) : Vec3d::Zero();
        p.position          = Narrow(centre + dir * Combine(op, len, x));
        return;
    }
    case Quantity::PositionBetweenTwoControlPoints: {
        const Vec3d  a = PointAt(frame, c.output_point0), b = PointAt(frame, c.output_point1);
        const Vec3d  ab  = b - a;
        const double len = ab.norm();
        const Vec3d  dir = len != 0.0 ? Vec3d(ab / len) : Vec3d::Zero();
        const Vec3d  rel = Wide(p.position) - a;
        const double along = rel.dot(dir);
        const Vec3d  perp  = rel - dir * along;
        const double t     = len != 0.0 ? along / len : 0.0;
        p.position         = Narrow(a + perp + dir * (Combine(op, t, x) * len));
        return;
    }
    case Quantity::Color: {
        const Vec3d colour = Lanes(c.output_component, Wide(p.color), Combine(op, Wide(p.color), value));
        if (birth) PM::InitColor(p, colour.x(), colour.y(), colour.z());
        else p.color = Narrow(colour);
        return;
    }
    case Quantity::Position: {
        const Vec3d origin = frame.world_space ? frame.layer_origin : Vec3d::Zero();
        const Vec3d current = Wide(p.position) + origin;
        p.position = Narrow(Lanes(c.output_component, current, Combine(op, current, value)) - origin);
        return;
    }
    case Quantity::Velocity:
        p.velocity = Narrow(Lanes(c.output_component, Wide(p.velocity), Combine(op, Wide(p.velocity), value)));
        return;
    case Quantity::DeltaToControlPoint: {
        const Vec3d centre = PointAt(frame, c.output_point0);
        const Vec3d delta  = centre - Wide(p.position);
        p.position = Narrow(centre - Lanes(c.output_component, delta, Combine(op, delta, value)));
        return;
    }
    case Quantity::DirectionToControlPoint: {
        const Vec3d  centre = PointAt(frame, c.output_point0);
        const Vec3d  delta  = centre - Wide(p.position);
        const double dist   = delta.norm();
        const Vec3d  dir    = dist > 0.0 ? Vec3d(delta / dist) : Vec3d::Zero();
        const Vec3d  now    = Lanes(c.output_component, dir, Combine(op, dir, value));
        const double len    = now.norm();
        p.position          = Narrow(centre - (len > 0.0 ? Vec3d(now * (dist / len)) : Vec3d::Zero()));
        return;
    }
    case Quantity::ControlPoint: {
        if (destination == nullptr) return;
        const Vec3d origin = frame.world_space ? frame.layer_origin : Vec3d::Zero();
        const Vec3d current = destination->offset + origin;
        const Vec3d next = c.output_component >= 0 && c.output_component <= 3
            ? Lanes(c.output_component, current, Combine(op, current, value)) : current;
        destination->offset = next - origin;
        // Three overlapping movups stores broadcast x/y/z. The last also
        // writes w=z; the scalar initializer leaves the affine w unchanged.
        if (!birth) destination->homogeneous = static_cast<float>(next.z());
        return;
    }
    // Lifetime fraction, the times and the layer origin have no destination.
    default: return;
    }
}

} // namespace

Config Read(const Json& record) {
    Config c;
    c.operation        = IndexOf(Text(record, "operation", "multiply"), { "remap", "multiply", "add", "subtract" }, 5);
    c.input            = QuantityOf(Text(record, "input", "lifetimefraction"));
    c.output           = QuantityOf(Text(record, "output", "size"));
    const auto component = [](const std::string& name) {
        return IndexOf(name, { "all", "x", "y", "z", "sum", "average", "max", "min" }, 9);
    };
    c.input_component  = component(Text(record, "inputcomponent", "all"));
    c.output_component = component(Text(record, "outputcomponent", "all"));
    c.transform = IndexOf(Text(record, "transformfunction", "none"),
                          { "none", "sine", "square", "saw", "triangle", "simplexnoise", "fbmnoise" }, 8);
    c.flags     = Integer(record, "flags", 1);
    c.input_min = Range(record, "inputrangemin", 0.0);
    c.input_range = Range(record, "inputrangemax", 1.0) - c.input_min;
    // A zero input range is held at 1.1920929e-7 (the loader's 0x34000000).
    for (int i = 0; i < 3; ++i)
        if (c.input_range[i] == 0.0) c.input_range[i] = 1.1920929e-7;
    c.output_min    = Range(record, "outputrangemin", 0.0);
    c.output_range  = Range(record, "outputrangemax", 1.0) - c.output_min;
    c.input_point0  = Point(Integer(record, "inputcontrolpoint0", 0));
    c.input_point1  = Point(Integer(record, "inputcontrolpoint1", 1));
    c.output_point0 = Point(Integer(record, "outputcontrolpoint0", 0));
    c.output_point1 = Point(Integer(record, "outputcontrolpoint1", 1));
    c.input_scale   = Number(record, "transforminputscale", 1.0);
    c.octaves       = Integer(record, "transformoctaves", 3);
    return c;
}

void Apply(const Config& c, Particle& p, const Frame& frame, bool birth, ParticleControlpoint* destination) {
    if (c.input == Quantity::Unknown || c.output == Quantity::Unknown) return;
    Vec3d in = InputOf(c, p, frame);
    if (IsVector(c.input)) in = Reduce(in, c.input_component);
    Vec3d value;
    for (int lane = 0; lane < 3; ++lane) {
        double n = (in[lane] - c.input_min[lane]) / c.input_range[lane];
        if (c.flags & 1) n = std::clamp(n, 0.0, 1.0);
        double v = c.output_min[lane] + Transform(c, n, lane, p, birth) * c.output_range[lane];
        if (c.flags & 2) v = std::clamp(v, 0.0, 1.0);
        value[lane] = v;
    }
    Write(c, p, value, frame, birth, destination);
}

bool ReadsLayerOrigin(const Json& record) {
    return QuantityOf(Text(record, "input", "lifetimefraction")) == Quantity::LayerOrigin;
}

bool ReadsTimeOfDay(const Json& record) {
    return QuantityOf(Text(record, "input", "lifetimefraction")) == Quantity::TimeOfDay;
}

} // namespace wallpaper::ParticleRemap
