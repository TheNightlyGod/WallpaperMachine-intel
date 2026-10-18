#include "WPParticleParser.hpp"
#include "Particle/ParticleEmitter.h"
#include "Particle/ParticleModify.h"
#include "Particle/ParticleSystem.h"
#include <random>
#include <memory>
#include <algorithm>
#include <cmath>
#include <optional>
#include <limits>
#include <sstream>

#include <Eigen/Dense>
#include <Eigen/Geometry>

#include "Utils/Logging.h"
#include "Utils/Algorism.h"
#include "Core/Random.hpp"

using namespace wallpaper;
using namespace Eigen;
namespace PM = ParticleModify;

namespace
{

/// The level an `audioprocessing*` block turns the spectrum into, in [0, 1].
/// The loudest band of the selected range decides (not the mean), then the
/// bounds, a smoothstep and the exponent shape it.
std::function<float()>
MakeAudioLevel(u32 mode, i32 start, i32 end, std::array<float, 2> bounds, float exponent,
               std::function<audio::AudioSpectrumSnapshot()> spectrum) {
    if (mode == 0 || mode > 3) return {};

    const int first = std::clamp(start, 0, 15);
    const int last  = std::max(first, std::clamp(end, 0, 15));
    return [mode, first, last, bounds, exponent, spectrum = std::move(spectrum)]() {
        if (! spectrum || ! std::isfinite(bounds[0]) || ! std::isfinite(bounds[1]) ||
            ! std::isfinite(exponent))
            return 0.0f;
        const auto snapshot = spectrum();
        // Stock effects/pulse/shaders/effects/pulse.vert AUDIOPROCESSING options:
        // 1=left, 2=right, 3=center (also authored by workshop 2562725207 emitters).
        const auto& bands  = mode == 1   ? snapshot.left16
                             : mode == 2 ? snapshot.right16
                                         : snapshot.average16;
        float       volume = 0.0f;
        for (int band = first; band <= last; ++band) {
            if (std::isfinite(bands[band])) volume = std::max(volume, bands[band]);
        }
        // Silence remains inactive even for exponent zero or negative bounds.
        if (volume <= 0.0f) return 0.0f;
        float response =
            bounds[1] > bounds[0]
                ? std::clamp((volume - bounds[0]) / (bounds[1] - bounds[0]), 0.0f, 1.0f)
                : (volume > bounds[0] ? 1.0f : 0.0f);
        if (response <= 0.0f) return 0.0f;
        // Match the stock audio response shaders: smooth bounds, then exponent.
        response = response * response * (3.0f - 2.0f * response);
        return std::pow(response, std::max(0.0f, exponent));
    };
}

std::function<float()>
MakeEmitterAudioResponse(const wpscene::Emitter&                       emitter,
                         std::function<audio::AudioSpectrumSnapshot()> spectrum) {
    return MakeAudioLevel(emitter.audioprocessingmode,
                          emitter.audioprocessingfrequencystart,
                          emitter.audioprocessingfrequencyend,
                          emitter.audioprocessingbounds,
                          emitter.audioprocessingexponent,
                          std::move(spectrum));
}

/// Wallpaper Engine keeps a control point index in 0..7: anything that is
/// not below 7 (negative values included) names the last one.
inline u32 ClampControlpointIndex(i32 value) {
    return static_cast<u32>(value) < 7u ? static_cast<u32>(value) : 7u;
}

/// The scene object's speed override as the speed-driven operators read it: a
/// file that ignores the override sees 1.
inline double SpeedScale(const wpscene::ParticleInstanceoverride& over, bool applies) {
    return applies ? static_cast<double>(over.speed) : 1.0;
}

/// The scene object's size override as the size records read it: a file that
/// ignores the override sees 1.
inline double SizeScale(const wpscene::ParticleInstanceoverride& over, bool applies) {
    return applies ? static_cast<double>(over.size) : 1.0;
}

inline double UnitRandom() { return Random::get(0.0, 1.0); }

/// `u` raised to the initializer's exponent, so values crowd toward the
/// minimum for an exponent above one. An exponent of exactly one is a plain draw.
inline double ExponentDraw(float exponent) {
    const double u = UnitRandom();
    return exponent == 1.0f ? u : std::pow(u, static_cast<double>(exponent));
}

// ---- colour -----------------------------------------------------------

/// Hue in [0, 1) by sixths, saturation and value as the usual max/min
/// definitions; hue and saturation are zero for a grey or black colour.
inline Vector3f RgbToHsv(const Vector3f& c) {
    const float mx    = c.maxCoeff();
    const float mn    = c.minCoeff();
    const float range = mx - mn;
    if (range < 1.0e-5f || mx <= 0.0f) return { 0.0f, 0.0f, std::max(mx, 0.0f) };
    float h;
    if (c.x() < mx) {
        h = c.y() < mx ? (c.x() - c.y()) / range + 4.0f : (c.z() - c.x()) / range + 2.0f;
    } else {
        h = (c.y() - c.z()) / range;
    }
    h /= 6.0f;
    if (h < 0.0f) h += 1.0f;
    return { h, range / mx, mx };
}

inline Vector3f HsvToRgb(float h, float s, float v) {
    h -= std::floor(h);
    const float scaled = h * 6.0f;
    const int   sector = static_cast<int>(std::floor(scaled)) % 6;
    const float f      = scaled - std::floor(scaled);
    const float p      = v * (1.0f - s);
    const float q      = v * (1.0f - s * f);
    const float t      = v * (1.0f - s * (1.0f - f));
    switch (sector) {
    case 0: return { v, t, p };
    case 1: return { q, v, p };
    case 2: return { p, v, t };
    case 3: return { p, q, v };
    case 4: return { t, p, v };
    default: return { v, p, q };
    }
}

inline float Clamp01(float x) { return std::clamp(x, 0.0f, 1.0f); }

/// How far an instance's colour override moves the preset's own colour, in
/// hue, saturation and value.
struct ColorShift {
    bool  active { false };
    float dh { 0.0f };
    float ds { 0.0f };
    float dv { 0.0f };
};

inline ColorShift ComputeColorShift(const Vector3f& preset, const Vector3f& override_color) {
    ColorShift shift;
    if ((override_color - preset).cwiseAbs().maxCoeff() < 0.9f / 255.0f) return shift;
    const Vector3f a = RgbToHsv(preset);
    const Vector3f b = RgbToHsv(override_color);
    shift.active     = true;
    shift.dh         = b.x() - a.x();
    shift.ds         = b.y() - a.y();
    shift.dv         = b.z() - a.z();
    return shift;
}

inline Vector3f RetintColor(const Vector3f& rgb, const ColorShift& shift) {
    const Vector3f hsv = RgbToHsv(rgb);
    return HsvToRgb(hsv.x() + shift.dh, Clamp01(hsv.y() + shift.ds), Clamp01(hsv.z() + shift.dv));
}

/// The colour the scene object overrides the preset with, 0-1, if it does.
inline std::optional<Vector3f> OverrideColor(const wpscene::ParticleInstanceoverride* over) {
    if (over == nullptr || ! over->enabled) return std::nullopt;
    if (over->overColor)
        return Vector3f(over->color[0] / 255.0f, over->color[1] / 255.0f, over->color[2] / 255.0f);
    if (over->overColorn) return Vector3f(over->colorn[0], over->colorn[1], over->colorn[2]);
    return std::nullopt;
}

/// The shift to apply at this moment, or an inactive one without an override.
/// Read at spawn, so a colour bound to a user property takes effect on the
/// next particle.
inline ColorShift CurrentColorShift(const wpscene::ParticleInstanceoverride* over,
                                    const ParticleColorDefinition&           def) {
    const auto colour = OverrideColor(over);
    return colour ? ComputeColorShift(def.defaultColor, *colour) : ColorShift {};
}

inline Vector3f ParseColorTriple(const nlohmann::json& j, const char* key,
                                 const Vector3f& fallback) {
    std::array<float, 3> value { fallback.x(), fallback.y(), fallback.z() };
    if (j.contains(key)) GET_JSON_NAME_VALUE_NOWARN(j, key, value);
    return { value[0], value[1], value[2] };
}

// ---- blend window -----------------------------------------------------

/// The fade a particle's own age puts on an operator: it ramps in over
/// `[inStart, inEnd]` and out over `[outStart, outEnd]` of the lifetime.
struct BlendWindow {
    float inStart { 0.0f };
    float inEnd { 0.0f };
    float outStart { 1.0f };
    float outEnd { 1.0f };
    bool  enabled { false };

    static BlendWindow FromJson(const nlohmann::json& j) {
        BlendWindow w;
        GET_JSON_NAME_VALUE_NOWARN(j, "blendinstart", w.inStart);
        GET_JSON_NAME_VALUE_NOWARN(j, "blendinend", w.inEnd);
        GET_JSON_NAME_VALUE_NOWARN(j, "blendoutstart", w.outStart);
        GET_JSON_NAME_VALUE_NOWARN(j, "blendoutend", w.outEnd);
        w.inStart = std::min(w.inStart, w.inEnd - 0.0001f);
        w.outEnd  = std::max(w.outEnd, w.outStart + 0.0001f);
        const float in_length  = w.inEnd - w.inStart;
        const float out_length = w.outEnd - w.outStart;
        w.enabled = (w.inEnd > 0.01f || w.outStart < 0.99f) &&
                    (w.outStart - w.inEnd > 0.01f || in_length > 0.01f || out_length > 0.01f);
        return w;
    }

    /// 1 when the window is not in use.
    float Factor(double life) const {
        if (! enabled) return 1.0f;
        const float t = static_cast<float>(life);
        return Clamp01((t - inStart) / (inEnd - inStart)) *
               Clamp01((outEnd - t) / (outEnd - outStart));
    }
};

inline void ReadAudioBlock(const nlohmann::json& j, u32& mode, i32& start, i32& end,
                           std::array<float, 2>& bounds, float& exponent) {
    GET_JSON_NAME_VALUE_NOWARN(j, "audioprocessingmode", mode);
    GET_JSON_NAME_VALUE_NOWARN(j, "audioprocessingfrequencystart", start);
    GET_JSON_NAME_VALUE_NOWARN(j, "audioprocessingfrequencyend", end);
    GET_JSON_NAME_VALUE_NOWARN(j, "audioprocessingbounds", bounds);
    GET_JSON_NAME_VALUE_NOWARN(j, "audioprocessingexponent", exponent);
}

/// The audio level of an operator or initializer record: always 1 without
/// an `audioprocessingmode`; otherwise sampled once per call.
inline std::function<float()> ReadAudioLevel(const nlohmann::json& j,
                                             const ParticleParseContext& ctx) {
    u32                  mode { 0 };
    i32                  start { 0 };
    i32                  end { 1 };
    std::array<float, 2> bounds { 0.8f, 1.0f };
    float                exponent { 2.0f };
    ReadAudioBlock(j, mode, start, end, bounds, exponent);
    if (mode == 0 || mode > 3) return {};
    if (ctx.requires_audio) ctx.requires_audio();
    return MakeAudioLevel(mode, start, end, bounds, exponent, ctx.spectrum);
}

inline void Color(Particle& p, const Vector3f& lo, const Vector3f& hi, double u) {
    const Vector3f c = lo + static_cast<float>(u) * (hi - lo);
    PM::MutiplyInitColor(p, c.x(), c.y(), c.z());
}

inline Vector3d GenRandomVec3(const std::array<float, 3>& min, const std::array<float, 3>& max,
                              float exponent = 1.0f) {
    Vector3d result;
    for (int32_t i = 0; i < 3; i++) {
        result[i] = algorism::lerp(ExponentDraw(exponent), min[i], max[i]);
    }
    return result;
}

} // namespace

struct SingleRandom {
    float       min { 0.0f };
    float       max { 0.0f };
    float       exponent { 1.0f };
    static void ReadFromJson(const nlohmann::json& j, SingleRandom& r) {
        GET_JSON_NAME_VALUE_NOWARN(j, "min", r.min);
        GET_JSON_NAME_VALUE_NOWARN(j, "max", r.max);
        GET_JSON_NAME_VALUE_NOWARN(j, "exponent", r.exponent);
    };
    double Draw() const { return algorism::lerp(ExponentDraw(exponent), min, max); }
};
struct VecRandom {
    std::array<float, 3> min { 0.0f, 0.0f, 0.0f };
    std::array<float, 3> max { 0.0f, 0.0f, 0.0f };
    float                exponent { 1.0f };

    static void ReadFromJson(const nlohmann::json& j, VecRandom& r) {
        GET_JSON_NAME_VALUE_NOWARN(j, "min", r.min);
        GET_JSON_NAME_VALUE_NOWARN(j, "max", r.max);
        GET_JSON_NAME_VALUE_NOWARN(j, "exponent", r.exponent);
    };
};
struct TurbulentRandom {
    float  scale { 1.0f };
    double timescale { 1.0f };
    float  offset { 0.0f };
    float  speedmin { 100.0f };
    float  speedmax { 250.0f };
    float  phasemin { 0.0f };
    float  phasemax { 0.1f };

    std::array<float, 3> forward { 0.0f, 1.0f, 0.0f }; // x y z
    std::array<float, 3> right { 0.0f, 0.0f, 1.0f };
    std::array<float, 3> up { 1.0f, 0.0f, 0.0f };

    static void ReadFromJson(const nlohmann::json& j, TurbulentRandom& r) {
        GET_JSON_NAME_VALUE_NOWARN(j, "scale", r.scale);
        GET_JSON_NAME_VALUE_NOWARN(j, "timescale", r.timescale);
        GET_JSON_NAME_VALUE_NOWARN(j, "offset", r.offset);
        GET_JSON_NAME_VALUE_NOWARN(j, "speedmin", r.speedmin);
        GET_JSON_NAME_VALUE_NOWARN(j, "speedmax", r.speedmax);
        GET_JSON_NAME_VALUE_NOWARN(j, "phasemin", r.phasemin);
        GET_JSON_NAME_VALUE_NOWARN(j, "phasemax", r.phasemax);
        GET_JSON_NAME_VALUE_NOWARN(j, "forward", r.forward);
        GET_JSON_NAME_VALUE_NOWARN(j, "right", r.right);
        GET_JSON_NAME_VALUE_NOWARN(j, "up", r.up);
    };
};
template<std::size_t N>
std::array<float, N> mapVertex(const std::array<float, N>& v, float (*oper)(float)) {
    std::array<float, N> result;
    std::transform(v.begin(), v.end(), result.begin(), oper);
    return result;
};

ParticleColorDefinition
WPParticleParser::analyzeColorSources(const std::vector<nlohmann::json>& initializers,
                                      const std::vector<nlohmann::json>& operators) {
    ParticleColorDefinition def;
    bool                    from_initializer = false;
    for (const auto& ini : initializers) {
        if (! ini.is_object() || ! ini.contains("name")) continue;
        std::string name;
        GET_JSON_NAME_VALUE_NOWARN(ini, "name", name);
        if (name == "colorrandom") {
            const Vector3f lo = ParseColorTriple(ini, "min", Vector3f::Zero()) / 255.0f;
            const Vector3f hi = ParseColorTriple(ini, "max", Vector3f::Constant(255.0f)) / 255.0f;
            def.defaultColor  = (lo + hi) * 0.5f;
            def.hasColor      = true;
            from_initializer  = true;
        } else if (name == "hsvcolorrandom") {
            float huemin { 0.0f }, huemax { 1.0f }, satmin { 0.5f }, satmax { 1.0f };
            float valmin { 0.5f }, valmax { 1.0f };
            GET_JSON_NAME_VALUE_NOWARN(ini, "huemin", huemin);
            GET_JSON_NAME_VALUE_NOWARN(ini, "huemax", huemax);
            GET_JSON_NAME_VALUE_NOWARN(ini, "saturationmin", satmin);
            GET_JSON_NAME_VALUE_NOWARN(ini, "saturationmax", satmax);
            GET_JSON_NAME_VALUE_NOWARN(ini, "valuemin", valmin);
            GET_JSON_NAME_VALUE_NOWARN(ini, "valuemax", valmax);
            def.defaultColor = HsvToRgb(
                (huemin + huemax) * 0.5f, (satmin + satmax) * 0.5f, (valmin + valmax) * 0.5f);
            def.hasColor     = true;
            from_initializer = true;
        } else if (name == "colorlist") {
            def.hasColor     = true;
            from_initializer = true;
            if (ini.contains("colors")) {
                const auto& colors = ini.at("colors");
                std::string text;
                if (colors.is_string()) {
                    text = colors.get<std::string>();
                } else if (colors.is_array() && ! colors.empty() && colors.front().is_string()) {
                    text = colors.front().get<std::string>();
                }
                std::istringstream stream(text);
                float              r = 1.0f, g = 1.0f, b = 1.0f;
                if (stream >> r >> g >> b) def.defaultColor = { r, g, b };
                else def.defaultColor = { 1.0f, 1.0f, 1.0f };
            } else {
                def.defaultColor = { 1.0f, 1.0f, 1.0f };
            }
        }
    }
    for (const auto& op : operators) {
        if (! op.is_object() || ! op.contains("name")) continue;
        std::string name;
        GET_JSON_NAME_VALUE_NOWARN(op, "name", name);
        if (name == "colorchange") {
            def.hasColor = true;
            if (! from_initializer) {
                def.defaultColor = ParseColorTriple(op, "startvalue", Vector3f::Ones());
            }
        }
    }
    return def;
}

ParticleInitOp WPParticleParser::genParticleInitOp(const nlohmann::json& wpj) {
    return genParticleInitOp(wpj, ParticleParseContext {});
}

ParticleInitOp WPParticleParser::genParticleInitOp(const nlohmann::json&        wpj,
                                                   const ParticleParseContext&  ctx) {
    using namespace std::placeholders;
    do {
        if (! wpj.contains("name")) break;
        std::string name;
        GET_JSON_NAME_VALUE(wpj, "name", name);

        if (name == "colorrandom") {
            VecRandom r;
            r.min = { 0.0f, 0.0f, 0.0f };
            r.max = { 255.0f, 255.0f, 255.0f };
            VecRandom::ReadFromJson(wpj, r);
            const auto over = ctx.over;
            const auto def  = ctx.color;

            return [=](Particle& p, double) {
                Vector3f lo = Vector3f(r.min[0], r.min[1], r.min[2]) / 255.0f;
                Vector3f hi = Vector3f(r.max[0], r.max[1], r.max[2]) / 255.0f;
                // An instance colour re-tints the preset's colours, keeping the
                // spread between them, instead of replacing them.
                const ColorShift shift = CurrentColorShift(over.get(), def);
                if (shift.active) {
                    lo = RetintColor(lo, shift);
                    hi = RetintColor(hi, shift);
                }
                // One draw for the three channels.
                Color(p, lo, hi, ExponentDraw(r.exponent));
            };
        } else if (name == "hsvcolorrandom") {
            float huemin { 0.0f }, huemax { 1.0f }, satmin { 0.5f }, satmax { 1.0f };
            float valmin { 0.5f }, valmax { 1.0f };
            i32   huesteps { 6 };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "huemin", huemin);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "huemax", huemax);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "huesteps", huesteps);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "saturationmin", satmin);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "saturationmax", satmax);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "valuemin", valmin);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "valuemax", valmax);
            huesteps = std::max(huesteps, 0);
            // The loader spaces the hue steps over the hue range. A range that
            // is a whole number of turns (the default 0..1) ends where it began,
            // so the last step would repeat the first and the range is divided
            // into `huesteps` pieces; any other range puts a step on both of its
            // ends and is divided into `huesteps - 1`. A range of no width is
            // taken as one whole turn, and one step or none leaves the hue alone.
            const float hue_range_raw = huemax - huemin;
            const float hue_range     = hue_range_raw != 0.0f ? hue_range_raw : 1.0f;
            float       hue_step      = 0.0f;
            if (huesteps > 1) {
                float divisor = static_cast<float>(huesteps) - 1.0f;
                if (std::fabs(std::fmod(hue_range, 1.0f)) < 1.0f / 360.0f) divisor += 1.0f;
                hue_step = hue_range / divisor;
            }
            // Width the hue steps are centred over when an instance colour sets
            // the hue: the range itself, none when the hue never changes.
            const float hue_width = huesteps > 1 ? hue_range : 0.0f;
            const auto  over      = ctx.over;
            const auto  def       = ctx.color;
            return [=](Particle& p, double) {
                float hue_lo = huemin;
                float sat_lo = satmin;
                float sat_hi = satmax;
                float val_lo = valmin;
                float val_hi = valmax;
                // An instance colour re-centres the ranges on its own hue,
                // saturation and value instead of adding to the preset's.
                if (const auto colour = OverrideColor(over.get());
                    colour && ComputeColorShift(def.defaultColor, *colour).active) {
                    const Vector3f hsv = RgbToHsv(*colour);
                    hue_lo = hsv.x() - hue_width * 0.5f;
                    const float sat_range = std::min(satmax - satmin, 1.0f);
                    sat_lo = Clamp01(hsv.y() - sat_range * 0.5f);
                    sat_hi = std::min(1.0f, sat_lo + sat_range);
                    const float val_range = std::min(valmax - valmin, 1.0f);
                    val_lo = Clamp01(hsv.z() - val_range * 0.5f);
                    val_hi = std::min(1.0f, val_lo + val_range);
                }
                const int index = huesteps > 0
                                      ? std::clamp(static_cast<int>(
                                                       std::floor(UnitRandom() * (huesteps + 1))),
                                                   0,
                                                   huesteps)
                                      : 0;
                const float    hue = hue_lo + static_cast<float>(index) * hue_step;
                const float    sat = static_cast<float>(algorism::lerp(UnitRandom(), sat_lo, sat_hi));
                const float    val = static_cast<float>(algorism::lerp(UnitRandom(), val_lo, val_hi));
                const Vector3f rgb = HsvToRgb(hue, sat, val);
                PM::MutiplyInitColor(p, rgb.x(), rgb.y(), rgb.z());
            };
        } else if (name == "colorlist") {
            std::vector<Vector3f> colors;
            std::string           text;
            if (wpj.contains("colors")) {
                const auto& value = wpj.at("colors");
                if (value.is_string()) {
                    text = value.get<std::string>();
                } else if (value.is_array()) {
                    for (const auto& entry : value) {
                        if (entry.is_string()) text += entry.get<std::string>() + " ";
                        else if (entry.is_number()) text += std::to_string(entry.get<double>()) + " ";
                    }
                }
            } else {
                text = "1 1 1";
            }
            {
                std::istringstream stream(text);
                float              r, g, b;
                while (stream >> r >> g >> b) colors.emplace_back(r, g, b);
            }
            if (colors.empty()) colors.emplace_back(1.0f, 1.0f, 1.0f);
            float huenoise { 0.0f }, saturationnoise { 0.0f }, valuenoise { 0.0f };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "huenoise", huenoise);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "saturationnoise", saturationnoise);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "valuenoise", valuenoise);
            const auto over = ctx.over;
            const auto def  = ctx.color;
            return [=](Particle& p, double) {
                const std::size_t pick = std::min<std::size_t>(
                    colors.size() - 1,
                    static_cast<std::size_t>(UnitRandom() * static_cast<double>(colors.size())));
                const Vector3f hsv = RgbToHsv(colors[pick]);
                // The noise is a uniform draw over the entry's own value plus
                // and minus the noise, with the two ends of that range kept
                // inside 0..1 (so the draw is cut off there, not piled up on
                // the edge).
                const auto noisy = [](float centre, float noise) {
                    const float lo = std::max(0.0f, centre - noise);
                    const float hi = std::min(1.0f, centre + noise);
                    return static_cast<float>(algorism::lerp(UnitRandom(), lo, hi));
                };
                float hue = noisy(hsv.x(), huenoise);
                float sat = noisy(hsv.y(), saturationnoise);
                float val = noisy(hsv.z(), valuenoise);
                // An instance colour moves every entry by the distance between
                // the override and the list's first entry, after the noise.
                if (const auto colour = OverrideColor(over.get());
                    colour && ComputeColorShift(def.defaultColor, *colour).active) {
                    const Vector3f first = RgbToHsv(colors.front());
                    const Vector3f ov    = RgbToHsv(*colour);
                    hue += ov.x() - first.x();
                    sat += ov.y() - first.y();
                    val += ov.z() - first.z();
                }
                sat = Clamp01(sat);
                val = Clamp01(val);
                const Vector3f rgb = HsvToRgb(hue, sat, val);
                PM::MutiplyInitColor(p, rgb.x(), rgb.y(), rgb.z());
            };
        } else if (name == "lifetimerandom") {
            SingleRandom r = { 0.0f, 1.0f };
            SingleRandom::ReadFromJson(wpj, r);
            return [=](Particle& p, double) {
                // Never shorter than a millisecond, so a particle always lives
                // long enough to be seen and to be aged out.
                PM::InitLifetime(p, std::max(static_cast<float>(r.Draw()), 0.001f));
            };
        } else if (name == "sizerandom") {
            // Wallpaper Engine's defaults: 5..50 in a pixel scene, 0.001..1 otherwise.
            SingleRandom r = ctx.ortho ? SingleRandom { 5.0f, 50.0f } : SingleRandom { 0.001f, 1.0f };
            SingleRandom::ReadFromJson(wpj, r);
            // Scales the size the particle has so far, as Wallpaper Engine's does:
            // a second `sizerandom` narrows the first's draw instead of replacing it.
            return [=](Particle& p, double) {
                PM::MutiplyInitSize(p, r.Draw());
            };
        } else if (name == "alpharandom") {
            SingleRandom r = { 0.05f, 1.0f };
            SingleRandom::ReadFromJson(wpj, r);
            // Scales the alpha so far, like the size and the colour initializers.
            return [=](Particle& p, double) {
                PM::MutiplyInitAlpha(p, r.Draw());
            };
        } else if (name == "velocityrandom") {
            VecRandom r;
            if (ctx.ortho) {
                r.min[0] = r.min[1] = -32.0f;
                r.max[0] = r.max[1] = 32.0f;
            } else {
                r.min = { -1.0f, -1.0f, -1.0f };
                r.max = { 1.0f, 1.0f, 1.0f };
            }
            VecRandom::ReadFromJson(wpj, r);
            const auto spawn = ctx.spawn;
            return [=](Particle& p, double) {
                Vector3d result = GenRandomVec3(r.min, r.max, r.exponent);
                if (spawn && spawn->has_world_linear) result = spawn->world_linear * result;
                PM::ChangeVelocity(p, result[0], result[1], result[2]);
            };
        } else if (name == "rotationrandom") {
            VecRandom r;
            r.max[2] = 2 * M_PI;
            VecRandom::ReadFromJson(wpj, r);
            return [=](Particle& p, double) {
                auto result = GenRandomVec3(r.min, r.max, r.exponent);
                PM::ChangeRotation(p, result[0], result[1], result[2]);
            };
        } else if (name == "angularvelocityrandom") {
            VecRandom r;
            r.min[2] = -5.0f;
            r.max[2] = 5.0f;
            VecRandom::ReadFromJson(wpj, r);
            return [=](Particle& p, double) {
                auto result = GenRandomVec3(r.min, r.max, r.exponent);
                PM::ChangeAngularVelocity(p, result[0], result[1], result[2]);
            };
        } else if (name == "inheritcontrolpointvelocity") {
            i32   controlpoint { 0 };
            float lo { 0.1f }, hi { 0.2f };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "controlpoint", controlpoint);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "min", lo);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "max", hi);
            const u32  index = ClampControlpointIndex(controlpoint);
            const auto spawn = ctx.spawn;
            if (! spawn) break;
            return [=](Particle& p, double) {
                if (index >= spawn->controlpoints.size() || spawn->frame_time <= 0.0) return;
                const auto&    cp = spawn->controlpoints[index];
                // How fast the control point itself is moving: the particle starts
                // with a share of it.
                const Vector3d v = (cp.offset - cp.prev_offset) / spawn->frame_time;
                PM::ChangeVelocity(p, v * algorism::lerp(UnitRandom(), lo, hi));
            };
        } else if (name == "positionoffsetrandom") {
            float distance { ctx.ortho ? 100.0f : 0.1f };
            float scale { ctx.ortho ? 0.001f : 1.0f };
            float timescale { 1.0f };
            i32   octaves { 6 };
            std::array<float, 3> directions { 1.0f, 1.0f, ctx.ortho ? 0.0f : 1.0f };
            std::array<int, 3>   sign { 0, 0, 0 };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "distance", distance);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "scale", scale);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "timescale", timescale);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "octaves", octaves);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "directions", directions);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "sign", sign);
            octaves         = std::clamp(octaves, 1, 16);
            const auto spawn = ctx.spawn;
            return [=](Particle& p, double) {
                const double time = spawn ? spawn->system_time * timescale : 0.0;
                // Noise summed over octaves at doubling frequency, halving in
                // weight, then averaged back into -1..1.
                auto fractal = [&](double a, double b, double bsign) {
                    double sum = 0.0, weight = 0.0, amplitude = 1.0, frequency = 1.0;
                    for (int k = 0; k < octaves; ++k) {
                        sum += amplitude * algorism::PerlinNoise(frequency * a, frequency * bsign * b, 0.0);
                        weight += amplitude;
                        amplitude *= 0.5;
                        frequency *= 2.0;
                    }
                    return sum / weight;
                };
                const double x = p.position.x() * scale;
                const double y = p.position.y() * scale;
                const double z = p.position.z() * scale;
                Vector3d     offset {
                    fractal(x, time, 1.0),
                    fractal(time, y, 1.0),
                    fractal(z, time, -1.0),
                };
                offset = offset.cwiseProduct(
                    Vector3d(directions[0], directions[1], directions[2])) * distance;
                for (int i = 0; i < 3; ++i) {
                    if (sign[i] != 0) offset[i] = std::abs(offset[i]) * (sign[i] > 0 ? 1.0 : -1.0);
                }
                PM::Move(p, offset);
            };
        } else if (name == "mapsequencearoundcontrolpoint") {
            i32                  count { 32 };
            std::array<float, 2> bounds { 0.0f, 1.0f };
            std::string          limit { "repeat" };
            i32                  controlpoint { 0 };
            std::array<float, 3> axis_in { 0.0f, 0.0f, 1.0f };
            std::array<float, 3> speedmin { 0.0f, 0.0f, 0.0f };
            std::array<float, 3> speedmax { 0.0f, 0.0f, 0.0f };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "count", count);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "bounds", bounds);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "limitbehavior", limit);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "controlpoint", controlpoint);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "axis", axis_in);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "speedmin", speedmin);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "speedmax", speedmax);
            const u32  index  = ClampControlpointIndex(controlpoint);
            const auto spawn  = ctx.spawn;
            if (! spawn) break;
            const bool mirror = limit == "mirror";
            double     phase { 0.0 };
            double     step { 1.0 / std::max(count, 1) };
            return [=](Particle& p, double) mutable {
                Vector3d centre = Vector3d::Zero();
                Vector3d axis(axis_in[0], axis_in[1], axis_in[2]);
                if (index < spawn->controlpoints.size()) {
                    const auto& cp = spawn->controlpoints[index];
                    centre         = cp.offset;
                    if (cp.has_rotation) axis = cp.rotation * axis;
                }
                if (axis.squaredNorm() < 1.0e-12) axis = Vector3d::UnitZ();
                axis.normalize();
                // Two directions across the axis, built the way Wallpaper Engine does.
                Vector3d u, v;
                if (axis.x() == 0.0 && axis.y() == 0.0) {
                    u = Vector3d::UnitX();
                    v = Vector3d::UnitY();
                } else {
                    u = Vector3d(axis.y(), -axis.x(), 0.0).normalized();
                    v = axis.cross(u).normalized();
                }
                const double theta = 2.0 * M_PI * (bounds[0] + phase * (bounds[1] - bounds[0]));
                const double ct = std::cos(theta), st = std::sin(theta);
                const Vector3d r      = p.position.cast<double>() - centre;
                const double   along  = r.dot(axis);
                const double   across = (r - along * axis).norm();
                const Vector3d d1     = ct * u + st * v;
                const Vector3d d2     = -st * u + ct * v;
                PM::MoveTo(p, centre + along * axis + across * d1);
                const Vector3d speed = d1 * (speedmin[1] + UnitRandom() * (speedmax[1] - speedmin[1])) +
                                       d2 * (speedmin[0] + UnitRandom() * (speedmax[0] - speedmin[0])) +
                                       axis * (speedmin[2] + UnitRandom() * (speedmax[2] - speedmin[2]));
                PM::ChangeVelocity(p, speed);

                phase += step;
                if (phase > 1.0) {
                    if (mirror) {
                        step  = -step;
                        phase = 2.0 - phase;
                    } else {
                        phase = std::fmod(phase, 1.0);
                    }
                }
                if (phase < 0.0) {
                    phase = -phase;
                    step  = -step;
                }
            };
        } else if (name == "mapsequencebetweencontrolpoints") {
            i32                  count { 32 };
            std::array<float, 2> bounds { 0.0f, 1.0f };
            std::string          limit { "repeat" };
            i32                  start { 0 }, end { 1 };
            i32                  flags { 0 };
            float                arcamount { 0.3f };
            float                sizereduction { 0.9f };
            std::array<float, 3> arcdirection { 0.0f, 1.0f, 0.0f };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "count", count);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "bounds", bounds);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "limitbehavior", limit);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "controlpointstart", start);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "controlpointend", end);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "flags", flags);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "arcamount", arcamount);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "arcdirection", arcdirection);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "sizereductionamount", sizereduction);
            const u32  start_index = ClampControlpointIndex(start);
            const u32  end_index   = ClampControlpointIndex(end);
            const auto spawn       = ctx.spawn;
            if (! spawn) break;
            const bool mirror = limit == "mirror";
            double     phase { 0.0 };
            // A single-particle sequence has no spacing: every spawn starts over.
            double step { count > 1 ? 1.0 / (count - 1) : 1.0e9 };
            return [=](Particle& p, double) mutable {
                if (start_index < spawn->controlpoints.size() &&
                    end_index < spawn->controlpoints.size()) {
                    const Vector3d a      = spawn->controlpoints[start_index].offset;
                    const Vector3d b      = spawn->controlpoints[end_index].offset;
                    const double   length = (b - a).norm();
                    if (length > 1.0e-9) {
                        const Vector3d dir  = (b - a) / length;
                        const Vector3d pos  = p.position.cast<double>();
                        const Vector3d perp = pos - pos.dot(dir) * dir;
                        const double   t    = bounds[0] + phase * (bounds[1] - bounds[0]);
                        // 1 in the middle of the sequence, 0 at both ends.
                        const double g = 1.0 - std::pow(std::abs(2.0 * phase - 1.0), 2.0);
                        Vector3d     moved = perp * (((flags & 1) != 0) ? g : 1.0) + t * length * dir + a;
                        if ((flags & 8) != 0) {
                            moved += Vector3d(arcdirection[0], arcdirection[1], arcdirection[2]) * g *
                                     length * arcamount;
                        }
                        PM::MoveTo(p, moved);
                        if ((flags & 2) != 0) p.velocity *= static_cast<float>(g);
                        if ((flags & 4) != 0) {
                            PM::MutiplyInitSize(p, (1.0 - sizereduction) + sizereduction * g);
                        }
                    }
                }
                phase += step;
                if (phase > 1.0) {
                    if (mirror) {
                        step  = -step;
                        phase = 2.0 - phase;
                    } else {
                        phase = 0.0;
                    }
                }
                if (phase < 0.0) {
                    phase = -phase;
                    step  = -step;
                }
            };
        } else if (name == "inheritinitialvaluefromevent") {
            std::string input { "setcolor" };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "input", input);
            const auto spawn = ctx.spawn;
            if (! spawn) break;
            return [=](Particle& p, double) {
                const Particle* parent = spawn->parent;
                if (parent == nullptr) return;
                if (input == "setcolor") {
                    PM::InitColor(p, parent->color.x(), parent->color.y(), parent->color.z());
                } else if (input == "multiplycolor") {
                    PM::MutiplyInitColor(p, parent->color.x(), parent->color.y(), parent->color.z());
                } else if (input == "setopacity") {
                    PM::InitAlpha(p, parent->alpha);
                } else if (input == "multiplyopacity") {
                    PM::MutiplyInitAlpha(p, parent->alpha);
                } else if (input == "setcoloropacity") {
                    PM::InitColor(p, parent->color.x(), parent->color.y(), parent->color.z());
                    PM::InitAlpha(p, parent->alpha);
                } else if (input == "multiplycoloropacity") {
                    PM::MutiplyInitColor(p, parent->color.x(), parent->color.y(), parent->color.z());
                    PM::MutiplyInitAlpha(p, parent->alpha);
                } else if (input == "setvelocity") {
                    p.velocity = parent->velocity;
                } else if (input == "addvelocity") {
                    PM::ChangeVelocity(p, parent->velocity.cast<double>());
                } else if (input == "setsize") {
                    PM::InitSize(p, parent->size);
                } else if (input == "multiplysize") {
                    // The engine multiplies its own size by the parent's own, each half of
                    // the size held here; `setsize` copies the same unit, so it needs no
                    // conversion.
                    PM::MutiplyInitSize(p, parent->size / kParticleSizeOverEngine);
                } else if (input == "setrotation") {
                    p.rotation = parent->rotation;
                } else if (input == "addrotation") {
                    PM::ChangeRotation(p, parent->rotation.cast<double>());
                } else if (input == "setangularvelocity") {
                    p.angularVelocity = parent->angularVelocity;
                } else if (input == "addangularvelocity") {
                    PM::ChangeAngularVelocity(p, parent->angularVelocity.cast<double>());
                }
            };
        } else if (name == "turbulentvelocityrandom") {
            // to do
            TurbulentRandom r;
            TurbulentRandom::ReadFromJson(wpj, r);
            Vector3f forward(r.forward.data());
            Vector3f right(r.right.data());
            Vector3f pos = GenRandomVec3({ 0, 0, 0 }, { 10.0f, 10.0f, 10.0f }).cast<float>();
            const auto spawn = ctx.spawn;
            return [=](Particle& p, double duration) mutable {
                float speed = Random::get(r.speedmin, r.speedmax);
                if (duration > 10.0f) {
                    pos[0] += speed;
                    duration = 0.0f;
                }
                Vector3f result;
                do {
                    result = algorism::CurlNoise(pos.cast<double>()).cast<float>().normalized();
                    pos += result * 0.005f / r.timescale;
                    duration -= 0.01f;
                } while (duration > 0.01f);
                // limit direction
                {
                    double c     = result.dot(forward) / (result.norm() * forward.norm());
                    float  a     = std::acos(c) / M_PI;
                    float  scale = r.scale / 2.0f;
                    if (a > scale) {
                        auto axis = result.cross(forward).normalized();
                        result    = AngleAxisf((a - a * scale) * M_PI, axis) * result;
                    }
                }
                // offset
                result = AngleAxisf(r.offset, right) * result;
                result *= speed;
                if (spawn && spawn->has_world_linear) {
                    result = (spawn->world_linear * result.cast<double>()).cast<float>();
                }
                PM::ChangeVelocity(p, result[0], result[1], result[2]);
            };
        }
    } while (false);
    return [](Particle&, double) {
    };
}

ParticleInitOp WPParticleParser::genOverrideInitOp(
    std::shared_ptr<const wpscene::ParticleInstanceoverride> over, ParticleColorDefinition def,
    bool speed_override, bool size_override) {
    return [over = std::move(over), def, speed_override, size_override](Particle& p, double) {
        PM::MutiplyInitLifeTime(p, over->lifetime);
        PM::MutiplyInitAlpha(p, over->alpha);
        if (size_override) PM::MutiplyInitSize(p, over->size);
        if (speed_override) PM::MutiplyVelocity(p, over->speed);
        // A file with colours of its own has them re-tinted by the colour
        // initializers; only a file without any takes the colour as a tint.
        if (! def.hasColor) {
            if (const auto colour = OverrideColor(over.get())) {
                PM::InitColor(p, colour->x(), colour->y(), colour->z());
            }
        }
        if (over->hdr && over->brightness != 1.0f) {
            PM::MutiplyInitColor(p, over->brightness, over->brightness, over->brightness);
        }
    };
}
double FadeValueChange(float life, float start, float end, float startValue,
                       float endValue) noexcept {
    if (life <= start)
        return startValue;
    else if (life > end)
        return endValue;
    else {
        double pass = (life - start) / (end - start);
        return algorism::lerp(pass, startValue, endValue);
    }
}

struct ValueChange {
    float starttime { 0 };
    float endtime { 1.0f };
    float startvalue { 1.0f };
    float endvalue { 0.0f };

    static auto ReadFromJson(const nlohmann::json& j) {
        ValueChange v;
        GET_JSON_NAME_VALUE_NOWARN(j, "starttime", v.starttime);
        GET_JSON_NAME_VALUE_NOWARN(j, "endtime", v.endtime);
        GET_JSON_NAME_VALUE_NOWARN(j, "startvalue", v.startvalue);
        GET_JSON_NAME_VALUE_NOWARN(j, "endvalue", v.endvalue);
        return v;
    }
};
double FadeValueChange(float life, const ValueChange& v) noexcept {
    return FadeValueChange(life, v.starttime, v.endtime, v.startvalue, v.endvalue);
}

struct VecChange {
    float                starttime { 0 };
    float                endtime { 1.0f };
    // Wallpaper Engine's defaults: the colour starts untouched and ends black.
    std::array<float, 3> startvalue { 1.0f, 1.0f, 1.0f };
    std::array<float, 3> endvalue { 0.0f, 0.0f, 0.0f };

    static auto ReadFromJson(const nlohmann::json& j) {
        VecChange v;
        GET_JSON_NAME_VALUE_NOWARN(j, "starttime", v.starttime);
        GET_JSON_NAME_VALUE_NOWARN(j, "endtime", v.endtime);
        GET_JSON_NAME_VALUE_NOWARN(j, "startvalue", v.startvalue);
        GET_JSON_NAME_VALUE_NOWARN(j, "endvalue", v.endvalue);
        return v;
    }
};

/// Oscillators: every particle takes one random (its `seed`) that picks its
/// frequency, phase and swing together.
struct Oscillation {
    std::array<float, 3> mask { 1.0f, 1.0f, 0.0f };

    float frequencymin { 1.0f };
    float frequencymax { 10.0f };
    float scalemin { 0.0f };
    float scalemax { 1.0f };
    float phasemin { 0.0f };
    float phasemax { static_cast<float>(2 * M_PI) };
    BlendWindow blend;

    static Oscillation ReadFromJson(const nlohmann::json& j, std::string_view name, bool ortho) {
        Oscillation v;
        if (name == "oscillatesize") {
            v.scalemin = 0.8f;
            v.scalemax = 1.2f;
        } else if (name == "oscillateposition") {
            v.frequencymax = 5.0f;
            v.scalemax     = ortho ? 10.0f : 0.5f;
        }
        GET_JSON_NAME_VALUE_NOWARN(j, "frequencymin", v.frequencymin);
        GET_JSON_NAME_VALUE_NOWARN(j, "frequencymax", v.frequencymax);
        GET_JSON_NAME_VALUE_NOWARN(j, "scalemin", v.scalemin);
        GET_JSON_NAME_VALUE_NOWARN(j, "scalemax", v.scalemax);
        GET_JSON_NAME_VALUE_NOWARN(j, "phasemin", v.phasemin);
        GET_JSON_NAME_VALUE_NOWARN(j, "phasemax", v.phasemax);
        GET_JSON_NAME_VALUE_NOWARN(j, "mask", v.mask);
        v.blend = BlendWindow::FromJson(j);
        return v;
    };

    double Frequency(const Particle& p) const {
        return frequencymin + static_cast<double>(p.seed) * (frequencymax - frequencymin);
    }
    double Phase(const Particle& p) const {
        return phasemin + static_cast<double>(p.seed) * (phasemax - phasemin);
    }
    /// The multiplier alpha or size takes, blended toward one by the window.
    double Multiplier(const Particle& p) const {
        const double arg = (Phase(p) + PM::LifetimePassed(p)) * Frequency(p);
        const double osc =
            scalemin + 0.5 * (std::sin(arg) + 1.0) * p.seed * (scalemax - scalemin);
        return 1.0 - (1.0 - osc) * blend.Factor(PM::LifetimePos(p));
    }
};

struct Turbulence {
    // the minimum time offset of the noise field for a particle.
    float phasemin { 0 };
    // the maximum time offset of the noise field for a particle.
    float phasemax { 0 };
    // the minimum velocity applied to particles.
    float speedmin { 500.0f };
    // the maximum velocity applied to particles.
    float speedmax { 1000.0f };
    // how fast the noise field changes shape.
    float timescale { 20.0f };

    float scale { 0.01f };

    std::array<float, 3> mask { 1.0f, 1.0f, 0.0f };
    BlendWindow          blend;

    static auto ReadFromJson(const nlohmann::json& j, bool ortho) {
        Turbulence v;
        if (! ortho) {
            v.speedmin  = 1.0f;
            v.speedmax  = 5.0f;
            v.timescale = 1.0f;
            v.scale     = 0.5f;
            v.mask      = { 1.0f, 1.0f, 1.0f };
        }
        GET_JSON_NAME_VALUE_NOWARN(j, "phasemin", v.phasemin);
        GET_JSON_NAME_VALUE_NOWARN(j, "phasemax", v.phasemax);
        GET_JSON_NAME_VALUE_NOWARN(j, "speedmin", v.speedmin);
        GET_JSON_NAME_VALUE_NOWARN(j, "speedmax", v.speedmax);
        GET_JSON_NAME_VALUE_NOWARN(j, "timescale", v.timescale);
        GET_JSON_NAME_VALUE_NOWARN(j, "mask", v.mask);
        GET_JSON_NAME_VALUE_NOWARN(j, "scale", v.scale);
        v.blend = BlendWindow::FromJson(j);
        return v;
    };
};

struct Vortex {
    enum class FlagEnum
    {
        infinit_axis = 0, // 1
    };
    using EFlags = BitFlags<FlagEnum>;

    i32 controlpoint { 0 };

    // anything below this distance receives force multiplied with speed inner.
    float distanceinner { 500.0f };
    // anything above this distance receives force multiplied with speed outer.
    float distanceouter { 650.0f };
    // amount of force applied to inner ring.
    float speedinner { 2500.0f };
    // amount of force applied to outer ring.
    float speedouter { 0 };

    EFlags flags { 0 };

    // positional offset from the center of the control point.
    std::array<float, 3> offset { 0.0f, 0.0f, 0.0f };

    // the axis to rotate around.
    std::array<float, 3> axis { 0.0f, 0.0f, 1.0f };
    BlendWindow          blend;

    static auto ReadFromJson(const nlohmann::json& j, bool ortho) {
        Vortex v;
        if (! ortho) {
            v.distanceinner = 1.0f;
            v.distanceouter = 2.0f;
            v.speedinner    = 1.0f;
        }
        GET_JSON_NAME_VALUE_NOWARN(j, "controlpoint", v.controlpoint);
        if (v.controlpoint >= 8) LOG_ERROR("wrong contropoint index %d", v.controlpoint);
        v.controlpoint = static_cast<i32>(ClampControlpointIndex(v.controlpoint));

        GET_JSON_NAME_VALUE_NOWARN(j, "distanceinner", v.distanceinner);
        GET_JSON_NAME_VALUE_NOWARN(j, "distanceouter", v.distanceouter);
        GET_JSON_NAME_VALUE_NOWARN(j, "speedinner", v.speedinner);
        GET_JSON_NAME_VALUE_NOWARN(j, "speedouter", v.speedouter);

        i32 _flags { 0 };
        GET_JSON_NAME_VALUE_NOWARN(j, "flags", _flags);
        v.flags = EFlags(_flags);

        GET_JSON_NAME_VALUE_NOWARN(j, "offset", v.offset);
        GET_JSON_NAME_VALUE_NOWARN(j, "axis", v.axis);
        v.blend = BlendWindow::FromJson(j);

        return v;
    };
};

struct ControlPointForce {
    i32 controlpoint { 0 };

    // how strongly the control point attracts or repels.
    float scale { 512.0f };
    // the maximum distance between particle and control point where the force takes effect.
    float threshold { 512.0f };
    // particles that pass within this distance of the control point are removed
    // (flag 1).
    float deletethreshold { 15.0f };
    // 1: remove particles that come within `deletethreshold`; 2: never pull a
    // particle past the control point.
    i32 flags { 0 };

    static auto ReadFromJson(const nlohmann::json& j, bool ortho) {
        ControlPointForce v;
        if (! ortho) {
            v.scale           = 20.0f;
            v.threshold       = 5.0f;
            v.deletethreshold = 0.5f;
        }
        GET_JSON_NAME_VALUE_NOWARN(j, "controlpoint", v.controlpoint);
        v.controlpoint = static_cast<i32>(ClampControlpointIndex(v.controlpoint));

        GET_JSON_NAME_VALUE_NOWARN(j, "scale", v.scale);
        if (j.contains("threshold")) {
            GET_JSON_NAME_VALUE_NOWARN(j, "threshold", v.threshold);
        } else {
            GET_JSON_NAME_VALUE_NOWARN(j, "threadhold", v.threshold);
        }
        GET_JSON_NAME_VALUE_NOWARN(j, "deletethreshold", v.deletethreshold);
        GET_JSON_NAME_VALUE_NOWARN(j, "flags", v.flags);
        return v;
    };
};

ParticleOperatorOp
WPParticleParser::genParticleOperatorOp(
    const nlohmann::json&                                   wpj,
    std::shared_ptr<const wpscene::ParticleInstanceoverride> over) {
    ParticleParseContext ctx;
    ctx.over = std::move(over);
    return genParticleOperatorOp(wpj, ctx);
}

ParticleOperatorOp WPParticleParser::genParticleOperatorOp(const nlohmann::json&       wpj,
                                                           const ParticleParseContext& ctx) {
    const auto over  = ctx.over != nullptr ? ctx.over
                                           : std::make_shared<const wpscene::ParticleInstanceoverride>();
    const bool ortho = ctx.ortho;
    const bool speed_applies = ctx.speed_override;
    const bool size_applies  = ctx.size_override;
    do {
        if (! wpj.contains("name")) break;
        std::string name;
        GET_JSON_NAME_VALUE(wpj, "name", name);
        if (name == "movement") {
            float drag { 0.0f };

            std::array<float, 3> gravity { 0, 0, 0 };
            i32                  flags { 0 };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "drag", drag);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "gravity", gravity);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "flags", flags);
            const Vector3d vecG = Vector3f(gravity.data()).cast<double>();
            return [drag, vecG, flags, over, speed_applies](const ParticleInfo& info) {
                // The speed override scales the gravity, not the damping.
                Vector3d g = vecG * SpeedScale(*over, speed_applies);
                // Bit 1 keeps gravity aligned to the screen however the layer is turned.
                if ((flags & 1) != 0) g = info.world_to_local * g;
                const double dt = info.time_pass;
                const double damp = 1.0 - std::min(static_cast<double>(drag) * dt, 0.9999999);
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    if (info.track_previous_position) p.prev_position = p.position;
                    // The position moves by the velocity after this step's
                    // acceleration and before its damping.
                    const Vector3d v1 = p.velocity.cast<double>() + g * dt;
                    PM::Move(p, v1 * dt);
                    p.velocity = (v1 * damp).cast<float>();
                }
            };
        } else if (name == "angularmovement") {
            float                drag { 0.0f };
            std::array<float, 3> force { 0, 0, 0 };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "drag", drag);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "force", force);
            const Vector3d vecF = Vector3f(force.data()).cast<double>();
            return [drag, vecF, over, speed_applies](const ParticleInfo& info) {
                const Vector3d f    = vecF * SpeedScale(*over, speed_applies);
                const double   dt   = info.time_pass;
                const double   damp = 1.0 - std::min(static_cast<double>(drag) * dt, 0.9999999);
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    const Vector3d w1 = p.angularVelocity.cast<double>() + f * dt;
                    PM::Rotate(p, w1 * dt);
                    p.angularVelocity = (w1 * damp).cast<float>();
                }
            };
        } else if (name == "sizechange") {
            auto vc        = ValueChange::ReadFromJson(wpj);
            // Every ramp of the file takes the instance's `size` override too: the
            // loader rescales each size record's start and change by it, so the
            // ramp multiplies the running size by `override * ramp`, on top of the
            // override the size draw already carries (override^(1 + ramps) in all).
            // A file that ignores the override sees 1.
            return [vc, over, size_applies](const ParticleInfo& info) {
                const auto size_over = SizeScale(*over, size_applies);
                for (auto& p : info.particles)
                    PM::MutiplySize(p, size_over * FadeValueChange(PM::LifetimePos(p), vc));
            };

        } else if (name == "alphafade") {
            float fadeintime { 0.5f }, fadeouttime { 0.5f };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "fadeintime", fadeintime);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "fadeouttime", fadeouttime);
            return [fadeintime, fadeouttime](const ParticleInfo& info) {
                for (auto& p : info.particles) {
                    auto life = PM::LifetimePos(p);
                    if (life <= fadeintime)
                        PM::MutiplyAlpha(p, FadeValueChange(life, 0, fadeintime, 0, 1.0f));
                    else if (life > fadeouttime)
                        PM::MutiplyAlpha(p,
                                         1.0f - FadeValueChange(life, fadeouttime, 1.0f, 0, 1.0f));
                }
            };
        } else if (name == "alphachange") {
            auto vc = ValueChange::ReadFromJson(wpj);
            return [vc](const ParticleInfo& info) {
                for (auto& p : info.particles) {
                    PM::MutiplyAlpha(p, FadeValueChange(PM::LifetimePos(p), vc));
                }
            };
        } else if (name == "colorchange") {
            auto vc  = VecChange::ReadFromJson(wpj);
            const auto def = ctx.color;
            // The ramp's two ends, re-tinted by an instance colour. The tint is
            // recomputed only when the override colour changes.
            struct Tinted {
                std::optional<Vector3f> key;
                bool                    valid { false };
                Vector3f                start { Vector3f::Ones() };
                Vector3f                end { Vector3f::Zero() };
            };
            return [vc, over, def, tinted = Tinted {}](const ParticleInfo& info) mutable {
                Vector3f start(vc.startvalue[0], vc.startvalue[1], vc.startvalue[2]);
                Vector3f end(vc.endvalue[0], vc.endvalue[1], vc.endvalue[2]);
                if (const auto colour = OverrideColor(over.get()); colour && def.hasColor) {
                    if (! tinted.valid || ! tinted.key || ! tinted.key->isApprox(*colour, 0.0f)) {
                        const ColorShift shift = ComputeColorShift(def.defaultColor, *colour);
                        tinted.key             = *colour;
                        tinted.start           = shift.active ? RetintColor(start, shift) : start;
                        tinted.end             = shift.active ? RetintColor(end, shift) : end;
                        tinted.valid           = true;
                    }
                    start = tinted.start;
                    end   = tinted.end;
                }
                for (auto& p : info.particles) {
                    auto     life = PM::LifetimePos(p);
                    Vector3f result;
                    for (uint i = 0; i < 3; i++)
                        result[i] =
                            FadeValueChange(life, vc.starttime, vc.endtime, start[i], end[i]);
                    PM::MutiplyColor(p, result[0], result[1], result[2]);
                }
            };
        } else if (name == "oscillatealpha") {
            const Oscillation osc = Oscillation::ReadFromJson(wpj, name, ortho);
            return [osc](const ParticleInfo& info) {
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    PM::MutiplyAlpha(p, osc.Multiplier(p));
                }
            };
        } else if (name == "oscillatesize") {
            const Oscillation osc = Oscillation::ReadFromJson(wpj, name, ortho);
            return [osc](const ParticleInfo& info) {
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    PM::MutiplySize(p, osc.Multiplier(p));
                }
            };

        } else if (name == "oscillateposition") {
            const Oscillation osc = Oscillation::ReadFromJson(wpj, name, ortho);
            return [osc, over, speed_applies](const ParticleInfo& info) {
                const double dt = info.time_pass;
                // The speed override scales the swing's frequency (alpha and size
                // oscillators do not read it).
                const double speed = SpeedScale(*over, speed_applies);
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    const double seed = p.seed;
                    const double f    = osc.Frequency(p) * speed;
                    const double ph   = osc.Phase(p);
                    const double t    = PM::LifetimePassed(p);
                    const double amp =
                        (osc.scalemin + seed * (osc.scalemax - osc.scalemin)) *
                        osc.blend.Factor(PM::LifetimePos(p));
                    // The offset is the difference of two evaluations, so a
                    // particle's displacement stays bounded by the swing.
                    const double wx =
                        amp * (std::sin((ph + t) * f) - std::sin((ph + t - dt) * f));
                    const double wy = amp * (std::sin((ph + 2.0 * M_PI * seed + t) * f) -
                                             std::sin((ph + 2.0 * M_PI * seed + t - dt) * f));
                    // z shares x's wave.
                    PM::Move(p, wx * osc.mask[0], wy * osc.mask[1], wx * osc.mask[2]);
                }
            };
        } else if (name == "turbulence") {
            Turbulence tur = Turbulence::ReadFromJson(wpj, ortho);
            const auto level = ReadAudioLevel(wpj, ctx);
            return [=](const ParticleInfo& info) {
                const double dt = info.time_pass;
                // Sampled once per step: the whole field swells and fades with the
                // sound; the speed override scales the particle speed range.
                const double audio =
                    (level ? static_cast<double>(level()) : 1.0) * SpeedScale(*over, speed_applies);
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    const double seed  = p.seed;
                    const double phase = seed * (tur.phasemax - tur.phasemin) + info.time * tur.timescale;
                    const double speed =
                        (tur.speedmin + seed * (tur.speedmax - tur.speedmin)) * audio *
                        static_cast<double>(tur.blend.Factor(PM::LifetimePos(p)));
                    const Vector3d q = ((p.position.cast<double>().array() + phase) * tur.scale).matrix();
                    const double nx = algorism::PerlinNoise(q.x(), q.y(), q.z());
                    const double ny = algorism::PerlinNoise(q.z(), q.x(), q.y());
                    const double nz = algorism::PerlinNoise(q.y(), q.z(), q.x());
                    PM::ChangeVelocity(p,
                                       nx * tur.mask[0] * dt * speed,
                                       ny * tur.mask[1] * dt * speed,
                                       nz * tur.mask[2] * dt * speed);
                }
            };
        } else if (name == "vortex") {
            Vortex v = Vortex::ReadFromJson(wpj, ortho);
            const auto level = ReadAudioLevel(wpj, ctx);
            return [=](const ParticleInfo& info) {
                const Vector3d centre = info.controlpoints[v.controlpoint].offset +
                                  (Vector3f { v.offset.data() }).cast<double>();
                Vector3d axis = (Vector3f { v.axis.data() }).cast<double>();
                if (axis.squaredNorm() >= 0.001) axis.normalize();
                const bool   infinite = v.flags[Vortex::FlagEnum::infinit_axis];
                const double span     = static_cast<double>(v.distanceouter) - v.distanceinner;
                const double speed_scale =
                    SpeedScale(*over, speed_applies) * (level ? static_cast<double>(level()) : 1.0);

                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    Vector3d d = p.position.cast<double>() - centre;
                    if (infinite) d -= d.dot(axis) * axis;
                    const double distance = d.norm();
                    if (distance < 1.0e-9) continue;
                    const double t = span > 1.0e-9
                                         ? std::clamp((distance - v.distanceinner) / span, 0.0, 1.0)
                                         : (distance >= v.distanceouter ? 1.0 : 0.0);
                    const double speed =
                        speed_scale * static_cast<double>(v.blend.Factor(PM::LifetimePos(p))) *
                        (v.speedinner + t * (static_cast<double>(v.speedouter) - v.speedinner));
                    // (pos - centre) x axis, over the distance to the axis.
                    const Vector3d tangent = d.cross(axis) / distance;
                    PM::Accelerate(p, tangent * speed, info.time_pass);
                }
            };
        } else if (name == "controlpointattract") {
            ControlPointForce c = ControlPointForce::ReadFromJson(wpj, ortho);
            const double delete_squared = static_cast<double>(c.deletethreshold) * c.deletethreshold;
            return [=](const ParticleInfo& info) {
                // Wallpaper Engine reads only the control point's position here.
                const Vector3d centre = info.controlpoints[c.controlpoint].offset;
                const double   dt     = info.time_pass;
                // The speed override scales the pull.
                const double scale = static_cast<double>(c.scale) * SpeedScale(*over, speed_applies);
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    const Vector3d d    = p.position.cast<double>() - centre;
                    const double   dist = d.norm();
                    if (dist > std::numeric_limits<float>::min() && dist < c.threshold) {
                        // The pull is strongest at the control point and falls
                        // to nothing at the threshold.
                        double k = (1.0 - dist / c.threshold) * scale * dt;
                        // Never carry a particle past the control point.
                        if ((c.flags & 2) != 0 && k > 0.0) k = std::min(k, dist);
                        PM::ChangeVelocity(p, -(d / dist) * k);
                    }
                    if ((c.flags & 1) != 0) {
                        // Remove a particle whose last step took it within the
                        // delete threshold of the control point: the path from
                        // where the movement operator found it to where it left it.
                        const Vector3d a = p.prev_position.cast<double>() - centre;
                        const Vector3d b = d;
                        const Vector3d e = b - a;
                        const double   l = e.squaredNorm();
                        const double   s = l > 1.0e-18 ? std::clamp(-a.dot(e) / l, 0.0, 1.0) : 0.0;
                        // Expires at the next age update, so an event child bound to
                        // the particle still sees it end.
                        if ((a + s * e).squaredNorm() <= delete_squared)
                            p.lifetime = std::numeric_limits<float>::min();
                    }
                }
            };
        } else if (name == "capvelocity") {
            float maxspeed { ortho ? 100.0f : 1.0f };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "maxspeed", maxspeed);
            const BlendWindow blend = BlendWindow::FromJson(wpj);
            return [maxspeed, blend](const ParticleInfo& info) {
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    const double speed = p.velocity.norm();
                    if (speed <= static_cast<double>(maxspeed) || speed <= 0.0) continue;
                    const double cap = maxspeed / speed;
                    const double b   = blend.Factor(PM::LifetimePos(p));
                    PM::MutiplyVelocity(p, 1.0 - b * (1.0 - cap));
                }
            };
        } else if (name == "reducemovementnearcontrolpoint") {
            i32   controlpoint { 0 };
            float inner { ortho ? 100.0f : 0.5f };
            float outer { ortho ? 350.0f : 1.0f };
            float reduction_inner { 100.0f };
            float reduction_outer { 0.0f };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "controlpoint", controlpoint);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "distanceinner", inner);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "distanceouter", outer);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "reductioninner", reduction_inner);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "reductionouter", reduction_outer);
            const u32 index = ClampControlpointIndex(controlpoint);
            return [=](const ParticleInfo& info) {
                const Vector3d centre = info.controlpoints[index].offset;
                const double   dt     = info.time_pass;
                const double   range  = static_cast<double>(outer) - inner;
                double         span   = static_cast<double>(reduction_outer) - reduction_inner;
                if (span == 0.0) span = 1.0;
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    const double distance = (p.position.cast<double>() - centre).norm();
                    const double s = range != 0.0 ? std::clamp((distance - inner) / range, 0.0, 1.0)
                                                   : (distance >= inner ? 1.0 : 0.0);
                    const double reduction =
                        std::clamp((reduction_inner + s * span) * dt, 0.0, 1.0);
                    PM::MutiplyVelocity(p, 1.0 - reduction);
                }
            };
        } else if (name == "maintaindistancetocontrolpoint") {
            i32   controlpoint { 0 };
            float distance { ortho ? 200.0f : 1.0f };
            float variablestrength { 0.0f };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "controlpoint", controlpoint);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "distance", distance);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "variablestrength", variablestrength);
            const u32 index = ClampControlpointIndex(controlpoint);
            return [=](const ParticleInfo& info) {
                const auto&    cp      = info.controlpoints[index];
                const Vector3d moved   = cp.offset - cp.prev_offset;
                const double   amount =
                    variablestrength == 0.0f
                        ? 1.0
                        : std::clamp(static_cast<double>(variablestrength) * info.time_pass, 0.0, 1.0);
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    // Ride along with the control point, then settle onto the
                    // shell at the wanted distance from it.
                    PM::Move(p, moved);
                    const Vector3d rel = p.position.cast<double>() - cp.offset;
                    const double   len = rel.norm();
                    if (len > 1.0e-9) PM::Move(p, (distance / len - 1.0) * amount * rel);
                }
            };
        } else if (name == "maintaindistancebetweencontrolpoints") {
            i32 start { 0 }, end { 1 };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "controlpointstart", start);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "controlpointend", end);
            const u32 start_index = ClampControlpointIndex(start);
            const u32 end_index   = ClampControlpointIndex(end);
            return [=](const ParticleInfo& info) {
                const auto&    s_cp = info.controlpoints[start_index];
                const auto&    e_cp = info.controlpoints[end_index];
                const Vector3d now  = e_cp.offset - s_cp.offset;
                const Vector3d was  = e_cp.prev_offset - s_cp.prev_offset;
                if (now.squaredNorm() <= 1.42e-14 || was.squaredNorm() <= 1.42e-14) return;
                const Vector3d slide = s_cp.offset - s_cp.prev_offset;
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    // The particle keeps its place along the segment, wherever
                    // the two ends have moved to.
                    const double along =
                        (p.position.cast<double>() - s_cp.prev_offset).dot(was) / was.squaredNorm();
                    PM::Move(p, slide + std::clamp(along, 0.0, 1.0) * now - along * was);
                }
            };
        } else if (name == "collisionplane" || name == "collisionsphere") {
            const bool           sphere = name == "collisionsphere";
            std::array<float, 3> plane { 0.0f, 1.0f, 0.0f };
            // A sphere's centre defaults to the scene's own idea of "below the
            // middle": 200 under the origin in a pixel scene.
            std::array<float, 3> origin { 0.0f, ortho ? -200.0f : 0.0f, 0.0f };
            float                distance { ortho ? -150.0f : 0.0f };
            float                radius { ortho ? 50.0f : 1.0f };
            float                bounce { 0.5f };
            std::string          behavior { "bounce" };
            i32                  controlpoint { 0 };
            i32                  flags { 0 };
            GET_JSON_NAME_VALUE_NOWARN(wpj, "plane", plane);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "origin", origin);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "distance", distance);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "radius", radius);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "bouncefactor", bounce);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "collisionbehavior", behavior);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "controlpoint", controlpoint);
            GET_JSON_NAME_VALUE_NOWARN(wpj, "flags", flags);
            const u32 index = ClampControlpointIndex(controlpoint);
            enum class Behavior { Bounce, Slide, Stop, Delete };
            Behavior mode = Behavior::Bounce;
            if (behavior == "slide") mode = Behavior::Slide;
            else if (behavior == "stop") mode = Behavior::Stop;
            else if (behavior == "delete") mode = Behavior::Delete;
            return [=](const ParticleInfo& info) {
                Vector3d normal(plane[0], plane[1], plane[2]);
                if (normal.squaredNorm() > 1.0e-12) normal.normalize();
                Vector3d centre(origin[0], origin[1], origin[2]);
                double   offset = static_cast<double>(distance);
                if ((flags & 1) != 0) {
                    // The shape is carried by the control point: a sphere is
                    // centred on it and a plane passes through it, turned by its
                    // orientation. The shape's own origin and distance are not read.
                    const auto& cp = info.controlpoints[index];
                    if (cp.has_rotation) normal = cp.rotation * normal;
                    centre = cp.offset;
                    offset = normal.dot(cp.offset);
                }
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    Vector3d n;
                    double   depth;
                    if (sphere) {
                        const Vector3d d = p.position.cast<double>() - centre;
                        const double   l = d.norm();
                        if (l >= radius || l < 1.0e-9) continue;
                        n     = d / l;
                        depth = l - radius; // negative inside
                    } else {
                        depth = p.position.cast<double>().dot(normal) - offset;
                        if (depth >= 0.0) continue;
                        n = normal;
                    }
                    // Back onto the surface.
                    PM::Move(p, -depth * n);
                    // Every particle that was found inside takes the response,
                    // whichever way it is moving: a bounce reflects its velocity
                    // along the surface normal and a slide takes that part away.
                    const double into = p.velocity.cast<double>().dot(n);
                    switch (mode) {
                    case Behavior::Bounce: PM::ChangeVelocity(p, -(1.0 + bounce) * into * n); break;
                    case Behavior::Slide: PM::ChangeVelocity(p, -into * n); break;
                    case Behavior::Stop: p.velocity = Vector3f::Zero(); break;
                    case Behavior::Delete:
                        p.lifetime = std::numeric_limits<float>::min();
                        break;
                    }
                }
            };
        }
    } while (false);
    return [](const ParticleInfo&) {
    };
}

ParticleEmittOp WPParticleParser::genParticleEmittOp(
    const wpscene::Emitter& wpe, bool sort,
    std::shared_ptr<const wpscene::ParticleInstanceoverride> override,
    std::function<audio::AudioSpectrumSnapshot()>            audio_spectrum,
    std::shared_ptr<ParticleSpawnContext>                    spawn) {
    std::shared_ptr<const float> count_multiplier;
    if (override != nullptr && override->enabled) {
        count_multiplier = std::shared_ptr<const float>(override, &override->count);
    }
    ParticleEmitterTiming timing;
    timing.delay               = wpe.delay;
    timing.duration            = wpe.duration;
    timing.periodic            = wpe.flags[wpscene::Emitter::FlagEnum::periodic];
    timing.minPeriodicDuration = wpe.minperiodicduration;
    timing.maxPeriodicDuration = wpe.maxperiodicduration;
    timing.minPeriodicDelay    = wpe.minperiodicdelay;
    timing.maxPeriodicDelay    = wpe.maxperiodicdelay;
    timing.maxToEmitPerPeriod  = wpe.maxtoemitperperiod;
    if (wpe.name == "boxrandom") {
        ParticleBoxEmitterArgs box;
        box.emitSpeed       = wpe.rate;
        box.minDistance     = wpe.distancemin;
        box.maxDistance     = wpe.distancemax;
        box.directions      = wpe.directions;
        box.orgin           = wpe.origin;
        box.one_per_frame   = wpe.flags[wpscene::Emitter::FlagEnum::one_per_frame];
        box.instantaneous   = wpe.instantaneous;
        box.minSpeed        = wpe.speedmin;
        box.maxSpeed        = wpe.speedmax;
        box.controlpoint    = wpe.controlpoint;
        box.sort            = sort;
        box.countMultiplier = count_multiplier;
        box.audioResponse   = MakeEmitterAudioResponse(wpe, std::move(audio_spectrum));
        box.timing          = timing;
        box.spawn           = std::move(spawn);
        return ParticleBoxEmitterArgs::MakeEmittOp(box);
    } else if (wpe.name == "sphererandom") {
        ParticleSphereEmitterArgs sphere;
        sphere.emitSpeed       = wpe.rate;
        sphere.minDistance     = wpe.distancemin[0];
        sphere.maxDistance     = wpe.distancemax[0];
        sphere.directions      = wpe.directions;
        sphere.orgin           = wpe.origin;
        sphere.sign            = wpe.sign;
        sphere.one_per_frame   = wpe.flags[wpscene::Emitter::FlagEnum::one_per_frame];
        sphere.instantaneous   = wpe.instantaneous;
        sphere.minSpeed        = wpe.speedmin;
        sphere.maxSpeed        = wpe.speedmax;
        sphere.controlpoint    = wpe.controlpoint;
        sphere.sort            = sort;
        sphere.countMultiplier = count_multiplier;
        sphere.audioResponse   = MakeEmitterAudioResponse(wpe, std::move(audio_spectrum));
        sphere.timing          = timing;
        sphere.cone            = wpe.cone;
        sphere.spawn           = std::move(spawn);
        return ParticleSphereEmitterArgs::MakeEmittOp(sphere);
    } else
        return [](std::vector<Particle>&,
                  std::vector<ParticleInitOp>&,
                  uint32_t,
                  double,
                  std::span<const ParticleControlpoint>) {
        };
}
