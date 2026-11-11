// Clean-room implementation from the WallpaperMachine spec e4-particle-simulation.md; written without access to the original source.
#include "WPParticleParser.hpp"
#include "ParticleLayerImage.hpp"
#include "WPParticleRemap.hpp"

#include <bit>

#include "Particle/ParticleNoise.h"
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
#include <mutex>
#include <string>
#include <unordered_set>
#include <map>

#include "Utils/Linalg.hpp"

#include "Utils/Logging.h"
#include "Utils/Algorism.h"
#include "Utils/Random.hpp"

using namespace wallpaper;
using namespace wallpaper::linalg;
namespace PM = ParticleModify;

namespace
{

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

inline Vector3f ParseColorTriple(const nlohmann::json& j, const char* key,
                                 const Vector3f& fallback) {
    std::array<float, 3> value { fallback.x(), fallback.y(), fallback.z() };
    if (j.contains(key)) GET_JSON_NAME_VALUE_NOWARN(j, key, value);
    return { value[0], value[1], value[2] };
}

/// Logs a record the engine does not decode, once for each distinct name.
void LogInertOnce(const char* kind, const std::string& name) {
    static std::mutex                     lock;
    static std::unordered_set<std::string> seen;
    const std::string                     key = std::string(kind) + ":" + name;
    {
        std::lock_guard<std::mutex> guard(lock);
        if (! seen.insert(key).second) return;
    }
    LOG_INFO("particle %s \"%s\" is not decoded and does nothing", kind, name.c_str());
}

/// The response of an audio-driven emitter, operator or initializer: the
/// loudest of the selected bands, mapped through the bounds, smoothed, and
/// raised to the exponent. Zero for anything that is silent or not a number.
float AudioLevel(const audio::AudioSpectrumSnapshot& snapshot, u32 mode, i32 band_start,
                 i32 band_end, float low, float high, float exponent) {
    const std::array<float, 16>& bands =
        mode == 1 ? snapshot.left16 : (mode == 2 ? snapshot.right16 : snapshot.average16);
    const i32 first = std::clamp(band_start, 0, 15);
    const i32 last  = std::clamp(std::max(band_end, first), first, 15);
    float     volume = 0.0f;
    for (i32 i = first; i <= last; ++i) {
        const float band = bands[static_cast<std::size_t>(i)];
        if (! std::isfinite(band)) return 0.0f;
        volume = std::max(volume, band);
    }
    if (! (volume > 0.0f) || ! std::isfinite(low) || ! std::isfinite(high) ||
        ! std::isfinite(exponent))
        return 0.0f;
    float response = 0.0f;
    if (high > low) {
        response = std::clamp((volume - low) / (high - low), 0.0f, 1.0f);
    } else {
        response = volume > low ? 1.0f : 0.0f;
    }
    if (! (response > 0.0f)) return 0.0f;
    response = response * response * (3.0f - 2.0f * response);
    return std::pow(response, std::max(0.0f, exponent));
}

/// The level callable of an emitter record, or empty when it has no audio mode.
std::function<float()>
MakeAudioResponse(const wpscene::Emitter&                              wpe,
                  const std::function<audio::AudioSpectrumSnapshot()>& spectrum) {
    if (wpe.audioprocessingmode < 1 || wpe.audioprocessingmode > 3) return {};
    return [spectrum, mode = wpe.audioprocessingmode, start = wpe.audioprocessingfrequencystart,
            end = wpe.audioprocessingfrequencyend, low = wpe.audioprocessingbounds[0],
            high = wpe.audioprocessingbounds[1], exponent = wpe.audioprocessingexponent]() {
        if (! spectrum) return 0.0f;
        return AudioLevel(spectrum(), mode, start, end, low, high, exponent);
    };
}

ParticleEmitterTiming TimingOf(const wpscene::Emitter& wpe) {
    ParticleEmitterTiming timing;
    timing.delay               = wpe.delay;
    timing.duration            = wpe.duration;
    timing.periodic            = wpe.flags[wpscene::Emitter::FlagEnum::periodic];
    timing.minPeriodicDuration = wpe.minperiodicduration;
    timing.maxPeriodicDuration = wpe.maxperiodicduration;
    timing.minPeriodicDelay    = wpe.minperiodicdelay;
    timing.maxPeriodicDelay    = wpe.maxperiodicdelay;
    timing.maxToEmitPerPeriod  = wpe.maxtoemitperperiod;
    return timing;
}

} // namespace

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


// ---------------------------------------------------------------------------
// Helpers shared by the initializer, override and operator generators.
// ---------------------------------------------------------------------------
namespace
{

using Vec3d = linalg::Vector3d;
using Json  = nlohmann::json;

/// A draw from [0, 1).
double Draw01() { return Random::get(0.0, 1.0); }

/// A draw shaped by the record's exponent: exactly 1 is a plain draw.
double DrawShaped(double exponent) {
    const double u = Draw01();
    return exponent == 1.0 ? u : std::pow(u, exponent);
}

double Lerp(double a, double b, double t) { return a + (b - a) * t; }

template<class T>
T ReadKey(const Json& j, const char* key, T value) {
    GET_JSON_NAME_VALUE_NOWARN(j, key, value);
    return value;
}

Vec3d ReadVec3(const Json& j, const char* key, const Vec3d& fallback) {
    std::array<float, 3> value { static_cast<float>(fallback.x()), static_cast<float>(fallback.y()),
                                 static_cast<float>(fallback.z()) };
    GET_JSON_NAME_VALUE_NOWARN(j, key, value);
    return { value[0], value[1], value[2] };
}

std::array<double, 2> ReadVec2(const Json& j, const char* key, const std::array<double, 2>& fallback) {
    std::array<float, 2> value { static_cast<float>(fallback[0]), static_cast<float>(fallback[1]) };
    GET_JSON_NAME_VALUE_NOWARN(j, key, value);
    return { value[0], value[1] };
}

/// Control point numbers: 0..6 name themselves, anything else names the last.
std::size_t ClampPoint(int index) {
    return (index >= 0 && index <= 6) ? static_cast<std::size_t>(index) : 7u;
}

const ParticleControlpoint* PointOf(std::span<const ParticleControlpoint> points, int index) {
    const std::size_t i = ClampPoint(index);
    return i < points.size() ? &points[i] : nullptr;
}

double FiniteOr(double value, double fallback) { return std::isfinite(value) ? value : fallback; }

// --- colour ----------------------------------------------------------------------

/// Hue in turns, saturation and value, of an RGB colour.
Vec3d RgbToHsv(const Vec3d& c) {
    const double mx = std::max({ c.x(), c.y(), c.z() });
    const double mn = std::min({ c.x(), c.y(), c.z() });
    const double range = mx - mn;
    if (! (mx > 0.0) || ! (range > 0.0)) return { 0.0, 0.0, std::max(mx, 0.0) };
    double h;
    if (c.x() >= mx) h = (c.y() - c.z()) / range;
    else if (c.y() >= mx) h = (c.z() - c.x()) / range + 2.0;
    else h = (c.x() - c.y()) / range + 4.0;
    h /= 6.0;
    h -= std::floor(h);
    return { h, range / mx, mx };
}

Vec3d HsvToRgbD(const Vec3d& hsv) {
    const Vector3f rgb = HsvToRgb(static_cast<float>(hsv.x()), static_cast<float>(hsv.y()),
                                  static_cast<float>(hsv.z()));
    return { rgb.x(), rgb.y(), rgb.z() };
}

double Frac(double v) { return v - std::floor(v); }

/// The colour side of the scene object's instance override, resolved once per
/// record: it remembers the file's own reference colour (and its HSV) and reads
/// the override record live every time it is asked, so a property that moves
/// the override shows in the next birth or step.
class OverrideTint {
public:
    /// The override colour moved from the reference: where it points and the
    /// HSV step (hue in turns, saturation, value) from the reference to it.
    struct Offset {
        Vec3d target;
        Vec3d hsv_step;
    };

    OverrideTint() = default;
    OverrideTint(std::shared_ptr<const wpscene::ParticleInstanceoverride> over,
                 const ParticleColorDefinition&                           file_colour)
        : m_over(std::move(over)),
          m_file_has_source(file_colour.hasColor),
          m_reference { file_colour.defaultColor.x(), file_colour.defaultColor.y(),
                        file_colour.defaultColor.z() },
          m_reference_hsv(RgbToHsv(m_reference)) {}

    /// The override colour on a 0..1 scale; nothing when the record is missing,
    /// disabled, or sets neither `color` nor `colorn`.
    std::optional<Vec3d> Colour() const {
        if (! m_over || ! m_over->enabled) return std::nullopt;
        if (m_over->overColor) {
            const auto& c = m_over->color;
            return Vec3d { c[0] / 255.0, c[1] / 255.0, c[2] / 255.0 };
        }
        if (m_over->overColorn) {
            const auto& c = m_over->colorn;
            if (c[0] < 0.0f) return std::nullopt; // native instance colour unset sentinel
            return Vec3d { c[0], c[1], c[2] };
        }
        return std::nullopt;
    }

    /// The flat tint of a file that has no colour source of its own.
    std::optional<Vec3d> FlatTint() const {
        return m_file_has_source ? std::nullopt : Colour();
    }

    /// The retint a colour-bearing file applies, if the override differs from
    /// the reference by at least 0.9/255 in some channel.
    std::optional<Offset> Shifted() const {
        if (! m_file_has_source) return std::nullopt;
        const auto colour = Colour();
        if (! colour) return std::nullopt;
        const Vec3d gap = *colour - m_reference;
        constexpr double kSame = 0.9 / 255.0;
        if (std::abs(gap.x()) < kSame && std::abs(gap.y()) < kSame && std::abs(gap.z()) < kSame)
            return std::nullopt;
        return Offset { *colour, RgbToHsv(*colour) - m_reference_hsv };
    }

    /// `rgb` moved in HSV by `step`: hue added modulo 1, saturation and value
    /// added and held in 0..1.
    static Vec3d Moved(const Vec3d& rgb, const Vec3d& step) {
        const Vec3d hsv = RgbToHsv(rgb);
        return HsvToRgbD({ Frac(hsv.x() + step.x()), std::clamp(hsv.y() + step.y(), 0.0, 1.0),
                           std::clamp(hsv.z() + step.z(), 0.0, 1.0) });
    }

private:
    std::shared_ptr<const wpscene::ParticleInstanceoverride> m_over;
    bool  m_file_has_source { false };
    Vec3d m_reference { 1.0, 1.0, 1.0 };
    Vec3d m_reference_hsv { 0.0, 0.0, 1.0 };
};

/// A draw between `centre - noise` and `centre + noise`, the interval cut off
/// at 0 and 1 before it is sampled.
double NoisyUnit(double centre, double noise) {
    const double lo = std::max(0.0, centre - noise);
    const double hi = std::min(1.0, centre + noise);
    return hi > lo ? Lerp(lo, hi, Draw01()) : lo;
}

/// The numbers of a `colors` value: a string, or the strings (or numbers) of an
/// array, read three to an entry. Nothing usable is one white entry.
std::vector<Vec3d> ColourEntries(const Json& record) {
    std::vector<double> numbers;
    const auto take_text = [&numbers](const std::string& text) {
        std::istringstream stream(text);
        double             value = 0.0;
        while (stream >> value) numbers.push_back(value);
    };
    const auto found = record.find("colors");
    if (found != record.end()) {
        const Json& colors = (found->is_object() && found->contains("value")) ? found->at("value") : *found;
        if (colors.is_string()) {
            take_text(colors.get<std::string>());
        } else if (colors.is_array()) {
            for (const auto& item : colors) {
                if (item.is_string()) take_text(item.get<std::string>());
                else if (item.is_number()) numbers.push_back(item.get<double>());
            }
        }
    }
    std::vector<Vec3d> entries;
    for (std::size_t i = 0; i + 2 < numbers.size(); i += 3)
        entries.push_back({ numbers[i], numbers[i + 1], numbers[i + 2] });
    if (entries.empty()) entries.push_back({ 1.0, 1.0, 1.0 });
    return entries;
}

/// Keeps the last finite value of a quantity that a script or property drives.
struct LastFinite {
    double value { 1.0 };
    double operator()(double v) {
        if (std::isfinite(v)) value = v;
        return value;
    }
};

/// The selectors of `inheritinitialvaluefromevent` and `inheritvaluefromevent`
/// (off_140484D90): "<mode><quantity>"; colour, opacity and size combine by set
/// or multiply, velocity, rotation and angular velocity by set or add.
enum class InheritQuantity { Colour, Opacity, ColourOpacity, Velocity, Size, Rotation, AngularVelocity };
enum class InheritMode { Set, Multiply, Add };

std::optional<std::pair<InheritQuantity, InheritMode>> InheritSelector(const std::string& name) {
    static const std::map<std::string, std::pair<InheritQuantity, InheritMode>> kSelectors = [] {
        std::map<std::string, std::pair<InheritQuantity, InheritMode>> table;
        const std::pair<const char*, InheritQuantity> quantities[] = {
            { "color", InheritQuantity::Colour },
            { "opacity", InheritQuantity::Opacity },
            { "coloropacity", InheritQuantity::ColourOpacity },
            { "velocity", InheritQuantity::Velocity },
            { "size", InheritQuantity::Size },
            { "rotation", InheritQuantity::Rotation },
            { "angularvelocity", InheritQuantity::AngularVelocity },
        };
        const std::pair<const char*, InheritMode> modes[] = { { "set", InheritMode::Set },
                                                              { "multiply", InheritMode::Multiply },
                                                              { "add", InheritMode::Add } };
        for (const auto& [quantity_name, quantity] : quantities) {
            for (const auto& [mode_name, mode] : modes) {
                const bool scalable = quantity == InheritQuantity::Colour || quantity == InheritQuantity::Opacity ||
                                      quantity == InheritQuantity::ColourOpacity || quantity == InheritQuantity::Size;
                if ((mode == InheritMode::Multiply && ! scalable) || (mode == InheritMode::Add && scalable)) continue;
                table[std::string(mode_name) + quantity_name] = { quantity, mode };
            }
        }
        return table;
    }();
    const auto found = kSelectors.find(name);
    if (found == kSelectors.end()) return std::nullopt;
    return found->second;
}

/// Takes `quantity` of `parent` into `child`. At birth the birth values change
/// too; each step (the operator) only the running values do.
void Inherit(Particle& child, const Particle& parent, InheritQuantity quantity, InheritMode mode, bool birth) {
    const bool assign = mode == InheritMode::Set;
    const auto take_colour = [&] {
        const Vec3d c = parent.color.cast<double>();
        if (birth) {
            if (assign) PM::InitColor(child, c.x(), c.y(), c.z());
            else PM::MutiplyInitColor(child, c.x(), c.y(), c.z());
        } else {
            child.color = assign ? parent.color : Vector3f(child.color.cwiseProduct(parent.color));
        }
    };
    const auto take_opacity = [&] {
        if (birth) {
            if (assign) PM::InitAlpha(child, parent.alpha);
            else PM::MutiplyInitAlpha(child, parent.alpha);
        } else {
            child.alpha = assign ? parent.alpha : child.alpha * parent.alpha;
        }
    };
    switch (quantity) {
    case InheritQuantity::Colour: take_colour(); break;
    case InheritQuantity::Opacity: take_opacity(); break;
    case InheritQuantity::ColourOpacity:
        take_colour();
        take_opacity();
        break;
    case InheritQuantity::Velocity:
        if (assign) PM::InitVelocity(child, parent.velocity.cast<double>());
        else PM::ChangeVelocity(child, parent.velocity.cast<double>());
        break;
    case InheritQuantity::Size: {
        // The engine's sizes are half of these: a product takes half of the parent's.
        const double factor = static_cast<double>(parent.size) / kParticleSizeOverEngine;
        if (birth) {
            if (assign) PM::InitSize(child, parent.size);
            else PM::MutiplyInitSize(child, factor);
        } else {
            child.size = assign ? parent.size : static_cast<float>(child.size * factor);
        }
        break;
    }
    case InheritQuantity::Rotation:
        if (assign) child.rotation = parent.rotation;
        else PM::Rotate(child, parent.rotation.cast<double>());
        break;
    case InheritQuantity::AngularVelocity:
        if (assign) child.angularVelocity = parent.angularVelocity;
        else PM::ChangeAngularVelocity(child, parent.angularVelocity.cast<double>());
        break;
    }
}

/// What an operator changed in `p` since `before`, weighed by `w`: the blend
/// window of a blended opcode whose kernel did not decompile (F-D6) lerps the
/// particle between its old and its new state.
void BlendInto(Particle& p, const Particle& before, double w) {
    if (w >= 1.0) return;
    const auto mix3 = [w](const Vector3f& a, const Vector3f& b) {
        return Vector3f((a.cast<double>() + (b.cast<double>() - a.cast<double>()) * w).cast<float>());
    };
    const auto mix = [w](float a, float b) { return static_cast<float>(a + (b - a) * w); };
    p.position        = mix3(before.position, p.position);
    p.velocity        = mix3(before.velocity, p.velocity);
    p.color           = mix3(before.color, p.color);
    p.rotation        = mix3(before.rotation, p.rotation);
    p.angularVelocity = mix3(before.angularVelocity, p.angularVelocity);
    p.alpha           = mix(before.alpha, p.alpha);
    p.size            = mix(before.size, p.size);
    p.lifetime        = mix(before.lifetime, p.lifetime);
    p.init.lifetime   = mix(before.init.lifetime, p.init.lifetime);
}

} // namespace

ParticleInitOp WPParticleParser::genParticleInitOp(const nlohmann::json& wpj) {
    return genParticleInitOp(wpj, ParticleParseContext {});
}

ParticleInitOp WPParticleParser::genParticleInitOp(const nlohmann::json&        wpj,
                                                   const ParticleParseContext&  ctx) {
    const ParticleInitOp inert = [](Particle&, double) {};
    if (! wpj.is_object() || ! wpj.contains("name") || ! wpj.at("name").is_string()) {
        LogInertOnce("initializer", "");
        return inert;
    }
    const std::string name = wpj.at("name").get<std::string>();
    const bool        pixel = ctx.ortho;
    const auto        spawn = ctx.spawn;
    const double      exponent = ReadKey<double>(wpj, "exponent", 1.0);

    // The layer matrix the spawning emitter's control point carries, if any.
    const auto through_layer = [spawn](const Vec3d& v) -> Vec3d {
        if (spawn && spawn->has_world_linear) return spawn->world_linear * v;
        return v;
    };

    if (name == "lifetimerandom") {
        const double lo = ReadKey<double>(wpj, "min", 0.0), hi = ReadKey<double>(wpj, "max", 1.0);
        // The override lifetime is bound to this record only (field 216 on
        // lifetimerandom, loader 0x1401C5490 L2605/L2620, guarded by file flag 64).
        const auto over = ctx.lifetime_override ? ctx.over : nullptr;
        LastFinite last;
        return [=](Particle& p, double) mutable {
            const double scale = (over && over->enabled) ? last(over->lifetime) : 1.0;
            const double life  = std::max(scale * Lerp(lo, hi, DrawShaped(exponent)), 0.001);
            PM::InitLifetime(p, static_cast<float>(life));
        };
    }
    if (name == "sizerandom") {
        const double lo = ReadKey<double>(wpj, "min", pixel ? 5.0 : 0.001);
        const double hi = ReadKey<double>(wpj, "max", pixel ? 50.0 : 1.0);
        return [=](Particle& p, double) {
            PM::MutiplyInitSize(p, Lerp(lo, hi, DrawShaped(exponent)));
        };
    }
    if (name == "alpharandom") {
        const double lo = ReadKey<double>(wpj, "min", 0.05), hi = ReadKey<double>(wpj, "max", 1.0);
        return [=](Particle& p, double) {
            PM::MutiplyInitAlpha(p, Lerp(lo, hi, DrawShaped(exponent)));
        };
    }
    if (name == "velocityrandom") {
        const Vec3d lo = ReadVec3(wpj, "min", pixel ? Vec3d { -32, -32, 0 } : Vec3d { -1, -1, -1 });
        const Vec3d hi = ReadVec3(wpj, "max", pixel ? Vec3d { 32, 32, 0 } : Vec3d { 1, 1, 1 });
        return [=](Particle& p, double) {
            Vec3d v;
            for (int i = 0; i < 3; ++i) v[i] = Lerp(lo[i], hi[i], DrawShaped(exponent));
            PM::ChangeVelocity(p, through_layer(v));
        };
    }
    if (name == "rotationrandom") {
        const Vec3d lo = ReadVec3(wpj, "min", { 0, 0, 0 });
        const Vec3d hi = ReadVec3(wpj, "max", { 0, 0, 2.0 * Pi });
        return [=](Particle& p, double) {
            Vec3d r;
            for (int i = 0; i < 3; ++i) r[i] = Lerp(lo[i], hi[i], DrawShaped(exponent));
            PM::Rotate(p, r);
        };
    }
    if (name == "angularvelocityrandom") {
        const Vec3d lo = ReadVec3(wpj, "min", { 0, 0, -5 });
        const Vec3d hi = ReadVec3(wpj, "max", { 0, 0, 5 });
        return [=](Particle& p, double) {
            Vec3d w;
            for (int i = 0; i < 3; ++i) w[i] = Lerp(lo[i], hi[i], DrawShaped(exponent));
            PM::ChangeAngularVelocity(p, w);
        };
    }
    if (name == "colorrandom") {
        const Vec3d lo = ReadVec3(wpj, "min", { 0, 0, 0 }) / 255.0;
        const Vec3d hi = ReadVec3(wpj, "max", { 255, 255, 255 }) / 255.0;
        const OverrideTint tint(ctx.colour_override ? ctx.over : nullptr, ctx.color);
        return [=](Particle& p, double) {
            Vec3d from = lo, to = hi;
            if (const auto moved = tint.Shifted()) {
                from = OverrideTint::Moved(from, moved->hsv_step);
                to   = OverrideTint::Moved(to, moved->hsv_step);
            }
            const double u = DrawShaped(exponent);
            PM::MutiplyInitColor(p, Lerp(from.x(), to.x(), u), Lerp(from.y(), to.y(), u),
                                 Lerp(from.z(), to.z(), u));
        };
    }
    if (name == "hsvcolorrandom") {
        const double hue_lo = ReadKey<double>(wpj, "huemin", 0.0);
        const double hue_hi = ReadKey<double>(wpj, "huemax", 1.0);
        const int    steps  = ReadKey<int32_t>(wpj, "huesteps", 6);
        const double sat_lo = ReadKey<double>(wpj, "saturationmin", 0.5);
        const double sat_hi = ReadKey<double>(wpj, "saturationmax", 1.0);
        const double val_lo = ReadKey<double>(wpj, "valuemin", 0.5);
        const double val_hi = ReadKey<double>(wpj, "valuemax", 1.0);
        const OverrideTint tint(ctx.colour_override ? ctx.over : nullptr, ctx.color);
        return [=](Particle& p, double) {
            double hmin = hue_lo, hmax = hue_hi;
            double smin = sat_lo, smax = sat_hi, vmin = val_lo, vmax = val_hi;
            if (const auto moved = tint.Shifted()) {
                // The ranges are recentred on the override colour.
                const Vec3d o     = RgbToHsv(moved->target);
                const double width = steps > 1 ? hue_hi - hue_lo : 0.0;
                hmin = o.x() - width / 2.0;
                hmax = hmin + (hue_hi - hue_lo);
                const double sw = std::min(std::abs(sat_hi - sat_lo), 1.0);
                const double vw = std::min(std::abs(val_hi - val_lo), 1.0);
                smin = std::clamp(o.y() - sw / 2.0, 0.0, 1.0);
                smax = std::clamp(o.y() + sw / 2.0, 0.0, 1.0);
                vmin = std::clamp(o.z() - vw / 2.0, 0.0, 1.0);
                vmax = std::clamp(o.z() + vw / 2.0, 0.0, 1.0);
            }
            double hue = hmin;
            if (steps > 1) {
                double range = hmax - hmin;
                if (range == 0.0) range = 1.0;
                const double turns = std::round(range);
                const bool   whole = turns != 0.0 && std::abs(range - turns) <= 1.0 / 360.0;
                const double step  = whole ? range / steps : range / (steps - 1);
                hue                = hmin + step * Random::get<int>(0, steps);
            }
            const double s = Lerp(smin, smax, Draw01());
            const double v = Lerp(vmin, vmax, Draw01());
            const Vec3d  rgb = HsvToRgbD({ Frac(hue), s, v });
            PM::MutiplyInitColor(p, rgb.x(), rgb.y(), rgb.z());
        };
    }
    if (name == "colorlist") {
        const std::vector<Vec3d> entries = ColourEntries(wpj);
        const double hue_noise = ReadKey<double>(wpj, "huenoise", 0.0);
        const double sat_noise = ReadKey<double>(wpj, "saturationnoise", 0.0);
        const double val_noise = ReadKey<double>(wpj, "valuenoise", 0.0);
        const OverrideTint tint(ctx.colour_override ? ctx.over : nullptr, ctx.color);
        return [=](Particle& p, double) {
            const Vec3d& entry = entries[static_cast<std::size_t>(
                Random::get<int>(0, static_cast<int>(entries.size()) - 1))];
            const Vec3d hsv = RgbToHsv(entry);
            Vec3d       rgb = HsvToRgbD({ NoisyUnit(hsv.x(), hue_noise), NoisyUnit(hsv.y(), sat_noise),
                                          NoisyUnit(hsv.z(), val_noise) });
            if (const auto moved = tint.Shifted())
                rgb = OverrideTint::Moved(rgb, RgbToHsv(moved->target) - RgbToHsv(entries.front()));
            PM::MutiplyInitColor(p, rgb.x(), rgb.y(), rgb.z());
        };
    }
    if (name == "turbulentvelocityrandom") {
        // 0x14023B340 case 9 (0x14023BDC0..0x14023BE84, F-D4.md):
        //   ph  = r * phaseΔ * audio + phasemin + system time
        //   a   = simplex1(ph * timescale * rate) * π * scale + offset
        //   dir = forward turned about right by a;  v += dir * (speedmin + r2 * speedΔ)
        const double scale     = ReadKey<double>(wpj, "scale", 1.0);
        const double timescale = ReadKey<double>(wpj, "timescale", 1.0);
        const double offset    = ReadKey<double>(wpj, "offset", 0.0);
        const double speed_lo  = ReadKey<double>(wpj, "speedmin", 100.0);
        const double speed_hi  = ReadKey<double>(wpj, "speedmax", 250.0);
        const double phase_lo  = ReadKey<double>(wpj, "phasemin", 0.0);
        const double phase_hi  = ReadKey<double>(wpj, "phasemax", 0.0);
        Vec3d forward = ReadVec3(wpj, "forward", { 0, 1, 0 });
        Vec3d right   = ReadVec3(wpj, "right", { 0, 0, 1 });
        forward = forward.norm() > 0.0 ? Vec3d(forward.normalized()) : Vec3d(0, 1, 0);
        right   = right.norm() > 0.0 ? Vec3d(right.normalized()) : Vec3d(0, 0, 1);
        const auto     over = ctx.over;
        // The phase range is scaled by the record's audio level (+0x44).
        const u32   audio_mode  = ReadKey<uint32_t>(wpj, "audioprocessingmode", 0u);
        const auto  bounds      = ReadKey<std::array<float, 2>>(wpj, "audioprocessingbounds", { 0.8f, 1.0f });
        const float audio_exp   = ReadKey<float>(wpj, "audioprocessingexponent", 2.0f);
        const i32   band_first  = ReadKey<int32_t>(wpj, "audioprocessingfrequencystart", 0);
        const i32   band_last   = ReadKey<int32_t>(wpj, "audioprocessingfrequencyend", 1);
        const bool  audio_on    = audio_mode >= 1 && audio_mode <= 3;
        const auto  spectrum    = ctx.spectrum;
        if (audio_on && ctx.requires_audio) ctx.requires_audio();
        LastFinite     last_rate;
        return [=](Particle& p, double) mutable {
            const double rate  = (over && over->enabled) ? std::fmax(0.01, last_rate(over->rate)) : 1.0;
            const double level = ! audio_on ? 1.0
                                 : spectrum ? AudioLevel(spectrum(), audio_mode, band_first, band_last,
                                                         bounds[0], bounds[1], audio_exp)
                                            : 0.0;
            const double time  = spawn ? spawn->system_time : 0.0;
            const double ph    = Draw01() * (phase_hi - phase_lo) * level + phase_lo + time;
            const double angle =
                ParticleNoise::Simplex1(static_cast<float>(ph * timescale * rate)) * Pi * scale + offset;
            const double c = std::cos(angle), s = std::sin(angle);
            const Vec3d  dir = forward * c + right.cross(forward) * s + right * (right.dot(forward) * (1.0 - c));
            PM::ChangeVelocity(p, through_layer(dir * Lerp(speed_lo, speed_hi, Draw01())));
        };
    }
    if (name == "inheritcontrolpointvelocity") {
        const int    index = ReadKey<int32_t>(wpj, "controlpoint", 0);
        const double lo = ReadKey<double>(wpj, "min", 0.1), hi = ReadKey<double>(wpj, "max", 0.2);
        return [=](Particle& p, double) {
            if (! spawn) return;
            const auto* point = PointOf(spawn->controlpoints, index);
            const double dt   = spawn->frame_time;
            if (point == nullptr || ! (dt > 0.0)) return;
            const Vec3d moved = point->offset - point->prev_offset;
            if (moved.x() == 0.0 && moved.y() == 0.0 && moved.z() == 0.0) return;
            PM::ChangeVelocity(p, moved / dt * Lerp(lo, hi, Draw01()));
        };
    }
    if (name == "positionoffsetrandom") {
        const double distance  = ReadKey<double>(wpj, "distance", pixel ? 100.0 : 0.1);
        const double scale     = ReadKey<double>(wpj, "scale", pixel ? 0.001 : 1.0);
        const double timescale = ReadKey<double>(wpj, "timescale", 1.0);
        const int    octaves   = std::clamp(ReadKey<int32_t>(wpj, "octaves", 6), 1, 16);
        const Vec3d  directions = ReadVec3(wpj, "directions", pixel ? Vec3d { 1, 1, 0 } : Vec3d { 1, 1, 1 });
        const Vec3d  sign       = ReadVec3(wpj, "sign", { 0, 0, 0 });
        return [=](Particle& p, double) {
            const double time = (spawn ? spawn->system_time : 0.0) * timescale;
            const Vec3d  pos  = PM::GetPos(p).cast<double>();
            Vec3d        shift {
                // 0x14023B340 positionoffsetrandom: three fbm calls of the 2D
                // simplex, arguments as listed (F-D3.md).
                ParticleNoise::Fbm2(static_cast<float>(pos.x() * scale), static_cast<float>(time), octaves),
                ParticleNoise::Fbm2(static_cast<float>(time), static_cast<float>(pos.y() * scale), octaves),
                ParticleNoise::Fbm2(static_cast<float>(pos.z() * scale), static_cast<float>(-time), octaves),
            };
            for (int i = 0; i < 3; ++i) {
                shift[i] *= directions[i] * distance;
                if (sign[i] != 0.0) shift[i] = std::abs(shift[i]) * (sign[i] > 0.0 ? 1.0 : -1.0);
            }
            PM::Move(p, shift);
        };
    }
    if (name == "mapsequencearoundcontrolpoint") {
        const double count = ReadKey<double>(wpj, "count", 32.0);
        const Vec3d  bounds = ReadVec3(wpj, "bounds", { 0, 1, 0 });
        const bool   mirror = ReadKey<std::string>(wpj, "limitbehavior", "repeat") == "mirror";
        const int    index  = ReadKey<int32_t>(wpj, "controlpoint", 0);
        const Vec3d  axis_in = ReadVec3(wpj, "axis", { 0, 0, 1 });
        const Vec3d  speed_lo = ReadVec3(wpj, "speedmin", { 0, 0, 0 });
        const Vec3d  speed_hi = ReadVec3(wpj, "speedmax", { 0, 0, 0 });
        // The phase walks through [0, 1] a step at a time, per instance.
        struct Sequence {
            double phase { 0.0 };
            double step { 0.0 };
        } sequence;
        sequence.step = 1.0 / std::max(count, 1.0);
        const auto advance = [mirror](Sequence& s) {
            s.phase += s.step;
            if (s.phase > 1.0 + 1.0e-9) {
                if (mirror) {
                    s.phase = 2.0 - s.phase;
                    s.step  = -s.step;
                } else {
                    s.phase = std::fmod(s.phase, 1.0);
                }
            } else if (s.phase < 0.0) {
                s.phase = -s.phase;
                s.step  = -s.step;
            }
        };
        return [=](Particle& p, double) mutable {
            const double phase = sequence.phase;
            advance(sequence);
            if (! spawn) return;
            const auto* point  = PointOf(spawn->controlpoints, index);
            const Vec3d centre = point ? point->offset : Vec3d::Zero();
            Vec3d       axis   = axis_in;
            if (point != nullptr && point->has_rotation) axis = point->rotation * axis;
            axis = axis.norm() > 0.0 ? Vec3d(axis.normalized()) : Vec3d(0, 0, 1);
            Vec3d u { 1, 0, 0 }, v { 0, 1, 0 };
            if (! (axis.x() == 0.0 && axis.y() == 0.0 && axis.z() > 0.0)) {
                u = Vec3d { axis.y(), -axis.x(), 0.0 };
                u = u.norm() > 0.0 ? Vec3d(u.normalized()) : Vec3d(1, 0, 0);
                v = axis.cross(u);
                v = v.norm() > 0.0 ? Vec3d(v.normalized()) : Vec3d(0, 1, 0);
            }
            const double angle = 2.0 * Pi * (bounds.x() + phase * (bounds.y() - bounds.x()));
            const Vec3d  d1 = u * std::cos(angle) + v * std::sin(angle);
            const Vec3d  d2 = u * -std::sin(angle) + v * std::cos(angle);
            const Vec3d  rel    = PM::GetPos(p).cast<double>() - centre;
            const double along  = rel.dot(axis);
            const double radial = (rel - axis * along).norm();
            PM::MoveTo(p, centre + axis * along + d1 * radial);
            const double out_speed   = Lerp(speed_lo.y(), speed_hi.y(), Draw01());
            const double spin_speed  = Lerp(speed_lo.x(), speed_hi.x(), Draw01());
            const double axis_speed  = Lerp(speed_lo.z(), speed_hi.z(), Draw01());
            PM::ChangeVelocity(p, d1 * out_speed + d2 * spin_speed + axis * axis_speed);
        };
    }
    if (name == "mapsequencebetweencontrolpoints") {
        const double count  = ReadKey<double>(wpj, "count", 32.0);
        const Vec3d  bounds = ReadVec3(wpj, "bounds", { 0, 1, 0 });
        const bool   mirror = ReadKey<std::string>(wpj, "limitbehavior", "repeat") == "mirror";
        const int    first  = ReadKey<int32_t>(wpj, "controlpointstart", 0);
        const int    last   = ReadKey<int32_t>(wpj, "controlpointend", 1);
        const int    flags  = ReadKey<int32_t>(wpj, "flags", 0);
        const double arc_amount = ReadKey<double>(wpj, "arcamount", 0.3);
        const Vec3d  arc_direction = ReadVec3(wpj, "arcdirection", { 0, 1, 0 });
        const double size_reduction = ReadKey<double>(wpj, "sizereductionamount", 0.9);
        struct Sequence {
            double phase { 0.0 };
            double step { 0.0 };
        } sequence;
        sequence.step = count > 1.0 ? 1.0 / (count - 1.0) : 0.0;
        return [=](Particle& p, double) mutable {
            const double phase = sequence.phase;
            sequence.phase += sequence.step;
            if (sequence.phase > 1.0 + 1.0e-9) {
                if (mirror) {
                    sequence.phase = 2.0 - sequence.phase;
                    sequence.step  = -sequence.step;
                } else {
                    sequence.phase = 0.0;
                }
            } else if (sequence.phase < 0.0) {
                sequence.phase = -sequence.phase;
                sequence.step  = -sequence.step;
            }
            if (! spawn) return;
            const auto* a_point = PointOf(spawn->controlpoints, first);
            const auto* b_point = PointOf(spawn->controlpoints, last);
            if (a_point == nullptr || b_point == nullptr) return;
            const Vec3d a = a_point->offset, b = b_point->offset;
            const double length = (b - a).norm();
            if (! (length > 0.0)) return;
            const Vec3d dir  = (b - a) / length;
            const Vec3d pos  = PM::GetPos(p).cast<double>();
            const Vec3d perp = pos - dir * pos.dot(dir);
            const double t   = bounds.x() + phase * (bounds.y() - bounds.x());
            const double g   = 1.0 - (2.0 * phase - 1.0) * (2.0 * phase - 1.0);
            Vec3d place = a + dir * (t * length) + perp * ((flags & 1) ? g : 1.0);
            if (flags & 8) place += arc_direction * (g * length * arc_amount);
            PM::MoveTo(p, place);
            if (flags & 2) PM::MutiplyVelocity(p, g);
            if (flags & 4) PM::MutiplyInitSize(p, (1.0 - size_reduction) + size_reduction * g);
        };
    }
    if (name == "inheritinitialvaluefromevent") {
        // Any selector outside the table does nothing.
        const auto chosen = InheritSelector(ReadKey<std::string>(wpj, "input", "setcolor"));
        if (! chosen) return inert;
        const auto [quantity, mode] = *chosen;
        return [=](Particle& p, double) {
            if (! spawn || spawn->parent == nullptr) return;
            Inherit(p, *spawn->parent, quantity, mode, true);
        };
    }
    if (name == "remapinitialvalue") {
        // sub_14023B340 case 0xF (artifacts/we-parity/decompiles/F-D11.md).
        const ParticleRemap::Config config = ParticleRemap::Read(wpj);
        if (config.output == ParticleRemap::Quantity::ControlPoint) {
            ParticleControlpoint* destination = config.output == ParticleRemap::Quantity::ControlPoint &&
                static_cast<std::size_t>(config.output_point0) < ctx.writable_controlpoints.size()
                ? &ctx.writable_controlpoints[config.output_point0] : nullptr;
            return [=](Particle& p, double) {
                ParticleRemap::Frame frame;
                if (spawn) {
                    frame.controlpoints = spawn->controlpoints;
                    frame.world_space   = spawn->world_space;
                    frame.system_time   = spawn->system_time;
                    frame.layer_time    = spawn->layer_time;
                    frame.time_of_day   = spawn->time_of_day;
                    frame.layer_origin  = spawn->layer_origin;
                }
                ParticleRemap::Apply(config, p, frame, true, destination);
            };
        }
        return [=](Particle& p, double) {
            ParticleRemap::Frame frame;
            if (spawn) {
                frame.controlpoints = spawn->controlpoints;
                frame.world_space   = spawn->world_space;
                frame.system_time   = spawn->system_time;
                frame.layer_time    = spawn->layer_time;
                frame.time_of_day   = spawn->time_of_day;
                frame.layer_origin  = spawn->layer_origin;
            }
            ParticleRemap::Apply(config, p, frame, true);
        };
    }
    LogInertOnce("initializer", name);
    return inert;
}

ParticleInitOp WPParticleParser::genOverrideInitOp(
    std::shared_ptr<const wpscene::ParticleInstanceoverride> over, ParticleColorDefinition def,
    bool speed_override, bool size_override, bool tint_after_retint, bool colour_override) {
    LastFinite alpha, size, speed, brightness;
    const OverrideTint tint(over, def);
    return [over = std::move(over), tint, speed_override, size_override, tint_after_retint, colour_override,
            alpha, size, speed, brightness](Particle& p, double) mutable {
        if (! over || ! over->enabled) return;
        // The record is read now, so a property that moved it shows in the next birth.
        // The lifetime override reaches `lifetimerandom` only (see there).
        PM::MutiplyInitAlpha(p, alpha(over->alpha));
        if (size_override) PM::MutiplyInitSize(p, size(over->size));
        if (speed_override) PM::MutiplyVelocity(p, speed(over->speed));
        if (const auto flat = tint.FlatTint()) PM::InitColor(p, flat->x(), flat->y(), flat->z());
        // A file with colours had them re-tinted by its initializers and operators;
        // in a scene saved before version 5 the newborn is then multiplied by the
        // override itself, once. Nothing moved (override equal to the file's
        // colour) means no multiply either.
        else if (const auto moved = tint.Shifted(); moved && tint_after_retint && colour_override)
            PM::MutiplyInitColor(p, moved->target.x(), moved->target.y(), moved->target.z());
        const double glow = brightness(over->brightness);
        // File flag 8 drops the brightness too (0x1401D15A0: tint = 1 when (flags & 8)).
        if (colour_override && over->hdr && glow != 1.0) PM::MutiplyInitColor(p, glow, glow, glow);
    };
}

// ---------------------------------------------------------------------------
// Operator helpers.
// ---------------------------------------------------------------------------
namespace
{

/// The instance override as an operator reads it each step: speed and size
/// factors, 1 when the record is absent, disabled, or the file ignores them.
struct OverrideReader {
    std::shared_ptr<const wpscene::ParticleInstanceoverride> over;
    bool       speed_applies { true };
    bool       size_applies { true };
    LastFinite last_speed;
    LastFinite last_size;
    LastFinite last_rate;

    double Speed() {
        return (speed_applies && over && over->enabled) ? last_speed(over->speed) : 1.0;
    }
    /// The override rate, at least 0.01 as the engine clamps it (0x14022AF30).
    double Rate() {
        return (over && over->enabled) ? std::fmax(0.01, last_rate(over->rate)) : 1.0;
    }
    double Size() {
        return (size_applies && over && over->enabled) ? last_size(over->size) : 1.0;
    }
};

/// The share of a particle's life over which an operator is in force, as a
/// fade-in edge and a fade-out edge on the life position 0..1. An envelope
/// whose keys leave the whole life untouched weighs 1 everywhere.
class LifeEnvelope {
public:
    explicit LifeEnvelope(const Json& record) {
        const double in_from  = ReadKey<double>(record, "blendinstart", 0.0);
        const double in_to    = ReadKey<double>(record, "blendinend", 0.0);
        const double out_from = ReadKey<double>(record, "blendoutstart", 1.0);
        const double out_to   = ReadKey<double>(record, "blendoutend", 1.0);
        // Each edge keeps a width of at least 0.0001.
        m_rise_from = std::min(in_from, in_to - 0.0001);
        m_rise_to   = in_to;
        m_fall_from = out_from;
        m_fall_to   = std::max(out_to, out_from + 0.0001);

        const double rise_width = m_rise_to - m_rise_from;
        const double fall_width = m_fall_to - m_fall_from;
        const double plateau    = m_fall_from - m_rise_to;
        const bool   touches    = m_rise_to > 0.01 || m_fall_from < 0.99;
        const bool   visible    = plateau > 0.01 || rise_width > 0.01 || fall_width > 0.01;
        m_enabled               = touches && visible;
    }

    /// The factor at life position `t`.
    double At(double t) const {
        if (! m_enabled) return 1.0;
        const double fade_in  = std::clamp((t - m_rise_from) / (m_rise_to - m_rise_from), 0.0, 1.0);
        const double fade_out = std::clamp((m_fall_to - t) / (m_fall_to - m_fall_from), 0.0, 1.0);
        return fade_in * fade_out;
    }

private:
    bool   m_enabled { false };
    double m_rise_from { 0.0 }, m_rise_to { 0.0 }, m_fall_from { 1.0 }, m_fall_to { 1.0 };
};

/// The `audioprocessing*` keys of an operator.
struct AudioGate {
    u32         mode { 0 };
    i32         first { 0 }, last { 1 };
    float       low { 0.8f }, high { 1.0f }, exponent { 2.0f };
    std::function<audio::AudioSpectrumSnapshot()> spectrum;

    static AudioGate Read(const Json& j, const ParticleParseContext& ctx) {
        AudioGate g;
        g.mode = ReadKey<uint32_t>(j, "audioprocessingmode", 0u);
        const auto bounds = ReadKey<std::array<float, 2>>(j, "audioprocessingbounds", { 0.8f, 1.0f });
        g.low      = bounds[0];
        g.high     = bounds[1];
        g.exponent = ReadKey<float>(j, "audioprocessingexponent", 2.0f);
        g.first    = ReadKey<int32_t>(j, "audioprocessingfrequencystart", 0);
        g.last     = ReadKey<int32_t>(j, "audioprocessingfrequencyend", 1);
        g.spectrum = ctx.spectrum;
        if (g.Enabled() && ctx.requires_audio) ctx.requires_audio();
        return g;
    }
    bool Enabled() const { return mode >= 1 && mode <= 3; }
    /// Sampled once per operator call.
    double Level() const {
        if (! Enabled()) return 1.0;
        if (! spectrum) return 0.0;
        return AudioLevel(spectrum(), mode, first, last, low, high, exponent);
    }
};

double RampValue(double t, double t_start, double t_end, double from, double to) {
    if (t <= t_start) return from;
    if (t > t_end || ! (t_end > t_start)) return to;
    return from + (to - from) * (t - t_start) / (t_end - t_start);
}

/// Smallest distance from `point` to the segment `a`..`b`.
double DistanceToSegment(const Vec3d& point, const Vec3d& a, const Vec3d& b) {
    const Vec3d  edge = b - a;
    const double len2 = edge.squaredNorm();
    const double t    = len2 > 0.0 ? std::clamp((point - a).dot(edge) / len2, 0.0, 1.0) : 0.0;
    return (a + edge * t - point).norm();
}

/// A particle an operator removes expires in the next ageing step.
void Remove(Particle& p) { p.lifetime = std::numeric_limits<float>::min(); }

enum class Collision { Bounce, Slide, Stop, Delete };

Collision CollisionOf(const std::string& name) {
    if (name == "slide") return Collision::Slide;
    if (name == "stop") return Collision::Stop;
    if (name == "delete") return Collision::Delete;
    return Collision::Bounce;
}

/// The keys every collision record shares (defaults sub_1401C00A0: bouncefactor
/// 0.5, behaviour bounce, flags 0, control point 0) and the response to a hit.
/// Flag 2 picks the response variant that also zeroes the angular velocity of
/// every particle it hits, for every collision kind (the response thunks such as
/// sub_14024F5E0 test `flags & 2`; artifacts/we-parity/decompiles/F-D13.md).
struct CollisionResponse {
    Collision how { Collision::Bounce };
    double    bounce { 0.5 };
    int       flags { 0 };
    int       controlpoint { 0 };

    static CollisionResponse Read(const nlohmann::json& wpj) {
        CollisionResponse r;
        r.how          = CollisionOf(ReadKey<std::string>(wpj, "collisionbehavior", "bounce"));
        r.bounce       = ReadKey<double>(wpj, "bouncefactor", 0.5);
        r.flags        = ReadKey<int32_t>(wpj, "flags", 0);
        r.controlpoint = ReadKey<int32_t>(wpj, "controlpoint", 0);
        return r;
    }
    bool LocksToControlpoint() const { return (flags & 1) != 0; }

    /// What the surface does to a particle it has put back outside.
    void operator()(Particle& p, const Vec3d& normal) const {
        const double along = PM::GetVelocity(p).cast<double>().dot(normal);
        switch (how) {
        case Collision::Bounce: PM::ChangeVelocity(p, normal * (-(1.0 + bounce) * along)); break;
        case Collision::Slide: PM::ChangeVelocity(p, normal * -along); break;
        case Collision::Stop: p.velocity = Vector3f::Zero(); break;
        case Collision::Delete: Remove(p); break;
        }
        if (flags & 2) p.angularVelocity = Vector3f::Zero();
    }
};

Vec3d TransformPoint(const linalg::Matrix4d& m, const Vec3d& p) {
    return m.topLeftCorner<3, 3>() * p + m.topRightCorner<3, 1>();
}

} // namespace

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
    const ParticleOperatorOp inert = [](const ParticleInfo&) {};
    if (! wpj.is_object() || ! wpj.contains("name") || ! wpj.at("name").is_string()) {
        LogInertOnce("operator", "");
        return inert;
    }
    const std::string name  = wpj.at("name").get<std::string>();
    const bool        pixel = ctx.ortho;
    OverrideReader    reader { ctx.over, ctx.speed_override, ctx.size_override, {}, {}, {} };

    if (name == "movement") {
        const double drag    = ReadKey<double>(wpj, "drag", 0.0);
        const Vec3d  gravity = ReadVec3(wpj, "gravity", { 0, 0, 0 });
        const int    flags   = ReadKey<int32_t>(wpj, "flags", 0);
        return [=](const ParticleInfo& info) mutable {
            const double dt = info.time_pass;
            Vec3d        g  = gravity * reader.Speed();
            if (flags & 1) g = info.world_to_local * g;
            // Case 1: drag over the scaled step, positions over the step (F-D5).
            const double keep = 1.0 - std::min(drag * info.time_pass_scaled, 0.9999999);
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                if (info.track_previous_position) p.prev_position = p.position;
                PM::Accelerate(p, g, dt);
                PM::MoveByTime(p, dt);
                if (drag != 0.0) PM::MutiplyVelocity(p, keep);
            }
        };
    }
    if (name == "angularmovement") {
        const double drag  = ReadKey<double>(wpj, "drag", 0.0);
        const Vec3d  force = ReadVec3(wpj, "force", { 0, 0, 0 });
        // Blended opcode 28 (0x14023FBC0 case 0x1C): the window weight w takes the
        // force, the turn and the drag, which is clamped before it is weighed.
        const LifeEnvelope blend(wpj);
        return [=](const ParticleInfo& info) mutable {
            const double dt   = info.time_pass;
            const Vec3d  push = force * reader.Speed();
            const double damp = std::min(drag * info.time_pass_scaled, 0.9999999);
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const double w    = blend.At(PM::LifetimePos(p));
                const double keep = 1.0 - w * damp;
                PM::AngularAccelerate(p, push * w, dt);
                PM::RotateByTime(p, dt * w);
                if (drag != 0.0) p.angularVelocity = (p.angularVelocity.cast<double>() * keep).cast<float>();
            }
        };
    }
    if (name == "sizechange" || name == "alphachange") {
        const double t0 = ReadKey<double>(wpj, "starttime", 0.0), t1 = ReadKey<double>(wpj, "endtime", 1.0);
        const double from = ReadKey<double>(wpj, "startvalue", 1.0), to = ReadKey<double>(wpj, "endvalue", 0.0);
        const bool   size = name == "sizechange";
        // Ramps visit every slot, a particle that expired this step included.
        return [=](const ParticleInfo& info) mutable {
            const double factor = size ? reader.Size() : 1.0;
            for (auto& p : info.particles) {
                const double value = RampValue(PM::LifetimePos(p), t0, t1, from, to);
                if (size) PM::MutiplySize(p, factor * value);
                else PM::MutiplyAlpha(p, value);
            }
        };
    }
    if (name == "colorchange") {
        const double t0 = ReadKey<double>(wpj, "starttime", 0.0), t1 = ReadKey<double>(wpj, "endtime", 1.0);
        const Vec3d  from = ReadVec3(wpj, "startvalue", { 1, 1, 1 });
        const Vec3d  to   = ReadVec3(wpj, "endvalue", { 0, 0, 0 });
        const OverrideTint tint(ctx.colour_override ? ctx.over : nullptr, ctx.color);
        return [=](const ParticleInfo& info) mutable {
            Vec3d a = from, b = to;
            if (const auto moved = tint.Shifted()) {
                a = OverrideTint::Moved(a, moved->hsv_step);
                b = OverrideTint::Moved(b, moved->hsv_step);
            }
            for (auto& p : info.particles) {
                const double t = PM::LifetimePos(p);
                PM::MutiplyColor(p, RampValue(t, t0, t1, a.x(), b.x()), RampValue(t, t0, t1, a.y(), b.y()),
                                 RampValue(t, t0, t1, a.z(), b.z()));
            }
        };
    }
    if (name == "alphafade") {
        const double fade_in  = ReadKey<double>(wpj, "fadeintime", 0.5);
        const double fade_out = ReadKey<double>(wpj, "fadeouttime", 0.5);
        // Case 3 of 0x14023FBC0: each fade is masked by its own test and the
        // two masked factors are ORed bit for bit, 1 where neither test holds
        // (artifacts/we-parity/decompiles/F-D8.md). WE takes approximate
        // reciprocals (rcpps); we divide exactly.
        const float in  = static_cast<float>(fade_in);
        const float out = static_cast<float>(fade_out);
        return [=](const ParticleInfo& info) {
            for (auto& p : info.particles) {
                const float t       = static_cast<float>(PM::LifetimePos(p));
                const bool  fading_in  = t < in;
                const bool  fading_out = out < t;
                if (! fading_in && ! fading_out) continue;
                uint32_t bits = 0;
                if (fading_in) bits |= std::bit_cast<uint32_t>(t / in);
                if (fading_out) bits |= std::bit_cast<uint32_t>((1.0f - t) / (1.0f - out));
                PM::MutiplyAlpha(p, std::bit_cast<float>(bits));
            }
        };
    }
    if (name == "oscillatealpha" || name == "oscillatesize" || name == "oscillateposition") {
        const bool   position = name == "oscillateposition";
        const bool   alpha    = name == "oscillatealpha";
        const double f_lo = ReadKey<double>(wpj, "frequencymin", 1.0);
        const double f_hi = ReadKey<double>(wpj, "frequencymax", position ? 5.0 : 10.0);
        const double s_lo = ReadKey<double>(wpj, "scalemin", (position || alpha) ? 0.0 : 0.8);
        const double s_hi = ReadKey<double>(wpj, "scalemax",
                                            position ? (pixel ? 10.0 : 0.5) : (alpha ? 1.0 : 1.2));
        const double ph_lo = ReadKey<double>(wpj, "phasemin", 0.0);
        const double ph_hi = ReadKey<double>(wpj, "phasemax", 2.0 * Pi);
        const Vec3d  mask  = ReadVec3(wpj, "mask", { 1, 1, 0 });
        const LifeEnvelope blend(wpj);
        return [=](const ParticleInfo& info) mutable {
            const double dt    = info.time_pass;
            const double speed = reader.Speed();
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const double seed      = p.seed;
                const double frequency = Lerp(f_lo, f_hi, seed);
                const double phase     = Lerp(ph_lo, ph_hi, seed);
                const double age       = PM::LifetimePassed(p);
                const double window    = blend.At(PM::LifetimePos(p));
                if (position) {
                    const double amp = (s_lo + seed * (s_hi - s_lo)) * window;
                    const double f   = frequency * speed;
                    const double wx  = amp * (std::sin((phase + age) * f) - std::sin((phase + age - dt) * f));
                    const double shifted = phase + 2.0 * Pi * seed;
                    const double wy  = amp * (std::sin((shifted + age) * f) - std::sin((shifted + age - dt) * f));
                    PM::Move(p, wx * mask.x(), wy * mask.y(), wx * mask.z());
                } else {
                    const double o = s_lo + 0.5 * (std::sin((phase + age) * frequency) + 1.0) * seed * (s_hi - s_lo);
                    const double factor = 1.0 - (1.0 - o) * window;
                    if (alpha) PM::MutiplyAlpha(p, factor);
                    else PM::MutiplySize(p, factor);
                }
            }
        };
    }
    if (name == "turbulence") {
        const double s_lo = ReadKey<double>(wpj, "speedmin", pixel ? 500.0 : 1.0);
        const double s_hi = ReadKey<double>(wpj, "speedmax", pixel ? 1000.0 : 5.0);
        const double timescale = ReadKey<double>(wpj, "timescale", pixel ? 20.0 : 1.0);
        const double scale     = ReadKey<double>(wpj, "scale", pixel ? 0.01 : 0.5);
        const Vec3d  mask = ReadVec3(wpj, "mask", pixel ? Vec3d { 1, 1, 0 } : Vec3d { 1, 1, 1 });
        const double ph_lo = ReadKey<double>(wpj, "phasemin", 0.0);
        const double ph_hi = ReadKey<double>(wpj, "phasemax", 0.0);
        const LifeEnvelope blend(wpj);
        const AudioGate   gate  = AudioGate::Read(wpj, ctx);
        return [=](const ParticleInfo& info) mutable {
            const double dt    = info.time_pass_scaled;   // case 0xE takes the scaled step
            const double level = gate.Level() * reader.Speed();
            const double rate  = reader.Rate();
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const double seed  = p.seed;
                // The override rate is bound to the timescale (field 220) on top of the
                // rate-scaled system time (Particles.md §3).
                const double phase = seed * (ph_hi - ph_lo) + info.time * timescale * rate;
                const Vec3d  q = (PM::GetPos(p).cast<double>() + Vec3d::Constant(phase)) * scale;
                const float  x = static_cast<float>(q.x()), y = static_cast<float>(q.y()),
                            z = static_cast<float>(q.z());
                // 3D simplex x 32 (0x1400FC220), axes permuted per lane as case 0xE does.
                const Vec3d field { ParticleNoise::Simplex3(x, y, z), ParticleNoise::Simplex3(z, x, y),
                                    ParticleNoise::Simplex3(y, z, x) };
                const double speed = Lerp(s_lo, s_hi, seed) * level * blend.At(PM::LifetimePos(p));
                PM::ChangeVelocity(p, field.cwiseProduct(mask) * (speed * dt));
            }
        };
    }
    if (name == "vortex") {
        const int    index = ReadKey<int32_t>(wpj, "controlpoint", 0);
        const double inner = ReadKey<double>(wpj, "distanceinner", pixel ? 500.0 : 1.0);
        const double outer = ReadKey<double>(wpj, "distanceouter", pixel ? 650.0 : 2.0);
        const double speed_in  = ReadKey<double>(wpj, "speedinner", pixel ? 2500.0 : 1.0);
        const double speed_out = ReadKey<double>(wpj, "speedouter", 0.0);
        const int    flags = ReadKey<int32_t>(wpj, "flags", 0);
        const Vec3d  offset = ReadVec3(wpj, "offset", { 0, 0, 0 });
        Vec3d        axis   = ReadVec3(wpj, "axis", { 0, 0, 1 });
        if (axis.squaredNorm() >= 0.001) axis = axis.normalized();
        // No blend window: the vortex block of the loader (L6420-6590) never
        // reads one (only vortex_v2 does).
        const AudioGate   gate  = AudioGate::Read(wpj, ctx);
        return [=](const ParticleInfo& info) mutable {
            const auto* point  = PointOf(info.controlpoints, index);
            const Vec3d centre = (point ? point->offset : Vec3d::Zero()) + offset;
            const double dt    = info.time_pass_scaled;
            const double level = gate.Level() * reader.Speed();
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                Vec3d d = PM::GetPos(p).cast<double>() - centre;
                if (flags & 1) d -= axis * d.dot(axis);
                const double r = d.norm();
                if (! (r > 1.0e-9)) continue;
                const double t = outer > inner ? std::clamp((r - inner) / (outer - inner), 0.0, 1.0)
                                               : (r >= outer ? 1.0 : 0.0);
                const double speed = level * Lerp(speed_in, speed_out, t);
                PM::ChangeVelocity(p, d.cross(axis) / r * (speed * dt));
            }
        };
    }
    if (name == "vortex_v2") {
        // Loader sub_1401BF2D0 / L5690, kernel 0x14023FBC0 case 0x10
        // (artifacts/we-parity/decompiles/F-D9.md). Flags: 1 measures from the
        // axis line (else from the point), 2 keeps the particle's distance with
        // `centerforce`, 4 swirls about a ring and pulls toward it.
        const int    flags = ReadKey<int32_t>(wpj, "flags", 0);
        const int    index = std::clamp(ReadKey<int32_t>(wpj, "controlpoint", 0), 0, 7);
        const double inner = ReadKey<double>(wpj, "distanceinner", pixel ? 500.0 : 1.0);
        const double outer = ReadKey<double>(wpj, "distanceouter", pixel ? 650.0 : 2.0);
        const double speed_in  = ReadKey<double>(wpj, "speedinner", pixel ? 2500.0 : 1.0);
        const double speed_out = ReadKey<double>(wpj, "speedouter", 0.0);
        const double centre_force = (flags & 2) ? ReadKey<double>(wpj, "centerforce", 1.0) : 0.0;
        const double ring_radius  = ReadKey<double>(wpj, "ringradius", pixel ? 300.0 : 1.0);
        const double ring_width   = ReadKey<double>(wpj, "ringwidth", pixel ? 50.0 : 0.2);
        const double pull_reach   = ReadKey<double>(wpj, "ringpulldistance", pixel ? 50.0 : 0.25);
        const double pull_force   = ReadKey<double>(wpj, "ringpullforce", pixel ? 10.0 : 0.05);
        const bool   ring   = (flags & 4) != 0;
        const bool   on_line = (flags & 1) != 0;
        const double low    = ring ? ring_width : inner;
        const double inv    = ring ? (pull_reach == 0.0 ? 1.0 : 1.0 / pull_reach)
                                   : (outer == inner ? 1.0 : 1.0 / (outer - inner));
        Vec3d        axis   = ReadVec3(wpj, "axis", { 0, 0, 1 });
        axis = axis.norm() >= 0.001 ? Vec3d(axis.normalized()) : Vec3d(0, 0, 1);
        // Blended opcode 37 did not decompile (F-D6): the window weighs the whole change.
        const LifeEnvelope blend(wpj);
        const AudioGate    gate = AudioGate::Read(wpj, ctx);
        return [=](const ParticleInfo& info) mutable {
            const auto* point = PointOf(info.controlpoints, index);
            const Vec3d centre = point ? point->offset : Vec3d::Zero();
            Vec3d       a      = axis;
            if (point != nullptr && point->has_rotation) {
                const Vec3d turned = point->rotation * axis;
                if (turned.norm() > 0.0) a = turned.normalized();
            }
            const double dt    = info.time_pass;
            const double a3    = info.time_pass_scaled;
            const double level = gate.Level() * reader.Speed();
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const Vec3d  d     = PM::GetPos(p).cast<double>() - centre;
                const double along = on_line ? d.dot(a) : 0.0;
                const Vec3d  flat  = d - a * along;
                const double r     = flat.norm();
                if (! (r > 0.0)) continue;
                const Vec3d  n = flat / r;
                // Where the particle goes this step, measured the same way.
                const Vec3d  q    = d + p.velocity.cast<double>() * dt - a * along;
                const double qlen = q.norm();
                double       radial = (qlen > 0.0 && dt > 0.0) ? (r / qlen - 1.0) * centre_force / dt : 0.0;
                double       t;
                if (ring) {
                    const double gap = ring_radius - r;
                    t                = std::clamp((std::abs(gap) - low) * inv, 0.0, 1.0);
                    const double keep = 1.0 - t;
                    const double pull = keep == 1.0 ? 0.0 : std::copysign(keep, gap);
                    radial += pull * dt * pull_force;
                } else {
                    t = std::clamp((r - low) * inv, 0.0, 1.0);
                }
                const double speed = Lerp(speed_in, speed_out, t) * level * a3;
                PM::ChangeVelocity(p, (n.cross(a) * speed + q * radial) * blend.At(PM::LifetimePos(p)));
            }
        };
    }
    if (name == "boids") {
        // Loader sub_1401BF700, kernel 0x14023FBC0 case 0x11
        // (artifacts/we-parity/decompiles/F-D10.md). No blend window, no audio.
        const double separation_reach = ReadKey<double>(wpj, "separationthreshold", pixel ? 20.0 : 0.02);
        const double neighbour_reach  = ReadKey<double>(wpj, "neighborthreshold", pixel ? 50.0 : 0.2);
        const double max_speed        = ReadKey<double>(wpj, "maxspeed", pixel ? 500.0 : 1.0);
        const double separation       = ReadKey<double>(wpj, "separationfactor", 15.0);
        const double alignment        = ReadKey<double>(wpj, "alignmentfactor", 1.0);
        const double cohesion         = ReadKey<double>(wpj, "cohesionfactor", 2.0);
        const int    flags            = ReadKey<int32_t>(wpj, "flags", 0);
        return [=](const ParticleInfo& info) {
            auto&             slots = info.particles;
            const std::size_t count = slots.size();
            if (count == 0) return;
            // The engine steers a slice of the particles each step, in blocks of
            // four, against a slice of the others, and scales the steering by
            // the number of slices: N = count / 200 + 1.
            const std::size_t slices = count / 200 + 1;
            const double      a3     = info.time_pass_scaled * static_cast<double>(slices);
            const std::size_t blocks = (count + 3) / 4;
            for (std::size_t b = info.step % slices; b < blocks; b += slices) {
                for (std::size_t i = 4 * b; i < std::min(count, 4 * b + 4); ++i) {
                    Particle& self = slots[i];
                    if (! PM::LifetimeOk(self)) continue;
                    const Vec3d pos = self.position.cast<double>();
                    Vec3d       sep = Vec3d::Zero(), sum_v = Vec3d::Zero(), sum_p = Vec3d::Zero();
                    double      near = 0.0, close = 0.0;
                    for (std::size_t c = (4 * b + info.step) % slices; c < blocks; c += slices) {
                        for (std::size_t j = 4 * c; j < std::min(count, 4 * c + 4); ++j) {
                            const Particle& other = slots[j];
                            if (! PM::LifetimeOk(other)) continue;
                            const Vec3d  d    = pos - other.position.cast<double>();
                            const double dist = d.norm();
                            if (dist < neighbour_reach) {   // the particle itself included
                                near += 1.0;
                                sum_v += other.velocity.cast<double>();
                                sum_p += other.position.cast<double>();
                            }
                            if (dist > 0.0 && dist < separation_reach) {
                                close += 1.0;
                                sep += d * (separation_reach / dist - 1.0);
                            }
                        }
                    }
                    const Vec3d v_old = self.velocity.cast<double>();
                    Vec3d       v     = v_old;
                    if (close > 0.0) v += sep * (separation * a3 / close);
                    if (near > 0.0) {
                        v += (sum_v / near - v_old) * (alignment * a3);
                        v += (sum_p / near - pos) * (cohesion * a3);
                    }
                    if (flags & 1) {
                        const double now2 = v.squaredNorm();
                        if (std::max(v_old.squaredNorm(), max_speed * max_speed) < now2)
                            v *= max_speed / std::sqrt(now2);
                    }
                    self.velocity = v.cast<float>();
                }
            }
        };
    }
    if (name == "remapvalue") {
        // Loader L6255, kernel 0x14023FBC0 case 0x13 (artifacts/we-parity/decompiles/F-D11.md).
        const ParticleRemap::Config config = ParticleRemap::Read(wpj);
        // Blended opcode 39 did not decompile (F-D6): the window lerps old and new.
        const LifeEnvelope blend(wpj);
        if (config.output == ParticleRemap::Quantity::ControlPoint) {
            ParticleControlpoint* destination = static_cast<std::size_t>(config.output_point0) < ctx.writable_controlpoints.size()
                ? &ctx.writable_controlpoints[config.output_point0] : nullptr;
            return [=](const ParticleInfo& info) {
                if (destination == nullptr) return;
                const ParticleRemap::Frame frame { .controlpoints = info.controlpoints,
                    .world_space = info.world_space, .system_time = info.time,
                    .layer_time = info.layer_time, .time_of_day = info.time_of_day,
                    .layer_origin = info.layer_origin };
                // The native SIMD kernel broadcasts lane zero into the point.
                for (std::size_t i = 0; i < info.particles.size(); i += 4) {
                    auto& p = info.particles[i];
                    const double weight = blend.At(PM::LifetimePos(p));
                    if (weight <= 0) continue;
                    const Vec3d before = destination->offset;
                    ParticleRemap::Apply(config, p, frame, false, destination);
                    if (weight < 1) destination->offset = before + (destination->offset - before) * weight;
                }
            };
        }
        return [=](const ParticleInfo& info) {
            const ParticleRemap::Frame frame { .controlpoints = info.controlpoints,
                                               .world_space = info.world_space,
                                               .system_time   = info.time,
                                               .layer_time    = info.layer_time,
                                               .time_of_day   = info.time_of_day,
                                               .layer_origin  = info.layer_origin };
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const double w = blend.At(PM::LifetimePos(p));
                if (w >= 1.0) {
                    ParticleRemap::Apply(config, p, frame, false);
                    continue;
                }
                const Particle before = p;
                ParticleRemap::Apply(config, p, frame, false);
                BlendInto(p, before, w);
            }
        };
    }
    if (name == "inheritvaluefromevent") {
        // Loader L5861 (default "setcoloropacity"), kernel 0x14023FBC0 case 0x14
        // (artifacts/we-parity/decompiles/F-D12.md): each step an event child takes
        // the quantity from its parent particle's running values while it lives.
        const auto chosen = InheritSelector(ReadKey<std::string>(wpj, "input", "setcoloropacity"));
        if (! chosen) return inert;
        const auto [quantity, mode] = *chosen;
        // Blended opcode 40 did not decompile (F-D6): the window lerps old and new.
        const LifeEnvelope blend(wpj);
        return [=](const ParticleInfo& info) {
            if (info.parent == nullptr) return;
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const Particle before = p;
                Inherit(p, *info.parent, quantity, mode, false);
                BlendInto(p, before, blend.At(PM::LifetimePos(p)));
            }
        };
    }
    if (name == "controlpointattract") {
        const int    index = ReadKey<int32_t>(wpj, "controlpoint", 0);
        const double scale = ReadKey<double>(wpj, "scale", pixel ? 512.0 : 20.0);
        double       threshold = pixel ? 512.0 : 5.0;
        if (wpj.contains("threshold")) threshold = ReadKey<double>(wpj, "threshold", threshold);
        else threshold = ReadKey<double>(wpj, "threadhold", threshold);
        const double delete_at = ReadKey<double>(wpj, "deletethreshold", pixel ? 15.0 : 0.5);
        const int    flags     = ReadKey<int32_t>(wpj, "flags", 0);
        // Blended opcode 32 (0x14023FBC0 case 0x20): the window weighs the pull after
        // flag 2 has capped it at the distance.
        const LifeEnvelope blend(wpj);
        return [=](const ParticleInfo& info) mutable {
            const auto* point  = PointOf(info.controlpoints, index);
            const Vec3d centre = point ? point->offset : Vec3d::Zero();
            const double dt    = info.time_pass_scaled;
            const double power = scale * reader.Speed();
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const Vec3d  pos = PM::GetPos(p).cast<double>();
                const Vec3d  d   = pos - centre;
                const double len = d.norm();
                if (len > 0.0 && len < threshold) {
                    double k = (1.0 - len / threshold) * power * dt;
                    if ((flags & 2) && k > 0.0) k = std::min(k, len);
                    k *= blend.At(PM::LifetimePos(p));
                    PM::ChangeVelocity(p, d / len * -k);
                }
                if ((flags & 1) &&
                    DistanceToSegment(centre, p.prev_position.cast<double>(), pos) < delete_at) {
                    Remove(p);
                }
            }
        };
    }
    if (name == "capvelocity") {
        const double max_speed = ReadKey<double>(wpj, "maxspeed", pixel ? 100.0 : 1.0);
        const LifeEnvelope blend(wpj);
        return [=](const ParticleInfo& info) {
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const double speed = PM::GetVelocity(p).cast<double>().norm();
                if (speed > max_speed && speed > 0.0) {
                    PM::MutiplyVelocity(p, 1.0 - blend.At(PM::LifetimePos(p)) * (1.0 - max_speed / speed));
                }
            }
        };
    }
    if (name == "reducemovementnearcontrolpoint") {
        const int    index = ReadKey<int32_t>(wpj, "controlpoint", 0);
        const double inner = ReadKey<double>(wpj, "distanceinner", pixel ? 100.0 : 0.5);
        const double outer = ReadKey<double>(wpj, "distanceouter", pixel ? 350.0 : 1.0);
        const double r_in  = ReadKey<double>(wpj, "reductioninner", 100.0);
        const double r_out = ReadKey<double>(wpj, "reductionouter", 0.0);
        // Blended opcode 35: the window weighs the reduction.
        const LifeEnvelope blend(wpj);
        return [=](const ParticleInfo& info) {
            const auto* point  = PointOf(info.controlpoints, index);
            const Vec3d centre = point ? point->offset : Vec3d::Zero();
            double      span   = r_out - r_in;
            if (span == 0.0) span = 1.0;
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const double dist = (PM::GetPos(p).cast<double>() - centre).norm();
                const double s = outer > inner ? std::clamp((dist - inner) / (outer - inner), 0.0, 1.0)
                                               : (dist > inner ? 1.0 : 0.0);
                const double reduction = std::clamp((r_in + s * span) * info.time_pass, 0.0, 1.0);
                PM::MutiplyVelocity(p, 1.0 - reduction * blend.At(PM::LifetimePos(p)));
            }
        };
    }
    if (name == "maintaindistancetocontrolpoint") {
        const int    index    = ReadKey<int32_t>(wpj, "controlpoint", 0);
        const double distance = ReadKey<double>(wpj, "distance", pixel ? 200.0 : 1.0);
        const double variable = ReadKey<double>(wpj, "variablestrength", 0.0);
        // Blended opcode 33: the window weighs the whole displacement.
        const LifeEnvelope blend(wpj);
        return [=](const ParticleInfo& info) {
            const auto* point = PointOf(info.controlpoints, index);
            if (point == nullptr) return;
            const Vec3d ride   = point->offset - point->prev_offset;
            const double amount = variable == 0.0 ? 1.0 : std::clamp(variable * info.time_pass, 0.0, 1.0);
            // Kernel 0xB (0x14024198B, artifacts/we-parity/decompiles/F-maintaindistance.md):
            // the distance is measured in the control point's frame, through the
            // inverse of its 3x3 (`sub_140228B00`), and the correction is applied in
            // the particle's own frame. A world-space system's control point carries
            // the layer's matrix, so a layer scaled by s keeps its particles
            // s·distance away (a rotation leaves the length alone, so only that
            // matrix counts).
            linalg::Matrix3d to_point = linalg::Matrix3d::Identity();
            if (point->has_world_linear) {
                const linalg::Matrix3d back = point->world_linear.inverse();
                if (back.allFinite()) to_point = back;
            }
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const double w = blend.At(PM::LifetimePos(p));
                PM::Move(p, ride * w);
                const Vec3d  rel = PM::GetPos(p).cast<double>() - point->offset;
                const double len = (to_point * rel).norm();
                if (len > 0.0) PM::Move(p, rel * ((distance / len - 1.0) * amount * w));
            }
        };
    }
    if (name == "maintaindistancebetweencontrolpoints") {
        const int first = ReadKey<int32_t>(wpj, "controlpointstart", 0);
        const int last  = ReadKey<int32_t>(wpj, "controlpointend", 1);
        // Blended opcode 34: the window weighs the whole displacement.
        const LifeEnvelope blend(wpj);
        return [=](const ParticleInfo& info) {
            const auto* a = PointOf(info.controlpoints, first);
            const auto* b = PointOf(info.controlpoints, last);
            if (a == nullptr || b == nullptr) return;
            const Vec3d was = b->prev_offset - a->prev_offset;
            const Vec3d now = b->offset - a->offset;
            if (was.squaredNorm() < 1.4e-14 || now.squaredNorm() < 1.4e-14) return;
            const Vec3d slide = a->offset - a->prev_offset;
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const double along = (PM::GetPos(p).cast<double>() - a->prev_offset).dot(was) / was.squaredNorm();
                PM::Move(p, (slide + now * std::clamp(along, 0.0, 1.0) - was * along) * blend.At(PM::LifetimePos(p)));
            }
        };
    }
    if (name == "collisionplane" || name == "collisionsphere") {
        const bool   sphere   = name == "collisionsphere";
        const auto   respond  = CollisionResponse::Read(wpj);
        const Vec3d  origin   = ReadVec3(wpj, "origin", pixel ? Vec3d { 0, -200, 0 } : Vec3d { 0, 0, 0 });
        const double distance = ReadKey<double>(wpj, "distance", pixel ? -150.0 : 0.0);
        const double radius   = ReadKey<double>(wpj, "radius", pixel ? 50.0 : 1.0);
        Vec3d        plane    = ReadVec3(wpj, "plane", { 0, 1, 0 });
        plane = plane.norm() > 0.0 ? Vec3d(plane.normalized()) : Vec3d::Zero();
        return [=](const ParticleInfo& info) {
            const auto* point =
                respond.LocksToControlpoint() ? PointOf(info.controlpoints, respond.controlpoint) : nullptr;
            if (sphere) {
                const Vec3d centre = point ? point->offset : origin;
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    const Vec3d  rel = PM::GetPos(p).cast<double>() - centre;
                    const double len = rel.norm();
                    if (! (len > 0.0) || len - radius >= 0.0) continue;
                    const Vec3d normal = rel / len;
                    PM::MoveTo(p, centre + normal * radius);
                    respond(p, normal);
                }
            } else {
                Vec3d normal = plane;
                double offset = distance;
                if (point != nullptr) {
                    if (point->has_rotation) normal = point->rotation * normal;
                    offset = normal.dot(point->offset);
                }
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    const double depth = normal.dot(PM::GetPos(p).cast<double>()) - offset;
                    if (! (depth < 0.0)) continue;
                    PM::Move(p, normal * -depth);
                    respond(p, normal);
                }
            }
        };
    }
    if (name == "collisionbox") {
        // Wallpaper Engine loads the record (controlpoint only) and its kernel
        // case 0x17 does nothing (0x1401C5490, F-D13.md).
        return inert;
    }
    if (name == "collisionbounds") {
        // Kernel 0x18 (sub_14024F660): four planes around the scene canvas,
        // n = (1,0,0), (0,1,0), (-1,0,0), (0,-1,0) through the points (0,0,0),
        // (0,0,0), (W,H,0), (W,H,0), both taken into the particles' frame (normals
        // with w = 0, so a scaled layer leaves them unnormalised). Per particle the
        // last plane in that order it is behind wins: pos -= (d - off)·n, then the
        // response with that n.
        const auto respond = CollisionResponse::Read(wpj);
        return [respond](const ParticleInfo& info) {
            const linalg::Matrix3d linear = info.scene_to_local.topLeftCorner<3, 3>();
            const Vec3d            low    = TransformPoint(info.scene_to_local, Vec3d::Zero());
            const Vec3d high = TransformPoint(info.scene_to_local, Vec3d(info.canvas.x(), info.canvas.y(), 0.0));
            std::array<Vec3d, 4>  normals { linear * Vec3d(1, 0, 0), linear * Vec3d(0, 1, 0),
                                           linear * Vec3d(-1, 0, 0), linear * Vec3d(0, -1, 0) };
            std::array<double, 4> offsets { low.dot(normals[0]), low.dot(normals[1]), high.dot(normals[2]),
                                            high.dot(normals[3]) };
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const Vec3d pos = PM::GetPos(p).cast<double>();
                int         hit = -1;
                double      depth = 0.0;
                for (int k = 0; k < 4; ++k) {
                    const double d = pos.dot(normals[k]) - offsets[k];
                    if (d < 0.0) {
                        hit   = k;
                        depth = d;
                    }
                }
                if (hit < 0) continue;
                PM::Move(p, normals[hit] * -depth);
                respond(p, normals[hit]);
            }
        };
    }
    if (name == "collisionquad") {
        // Loader defaults sub_1401C0870 and kernel sub_140253F70 (F-D13.md): a
        // particle that was in front of the quad's plane on the previous step and
        // is now on or behind it, inside its extents, is pushed out by 1.05·depth
        // (0x140492E70) along the normal. Flag 1 carries the quad with the control
        // point's translation and rotation.
        const auto respond = CollisionResponse::Read(wpj);
        const Vec3d origin = ReadVec3(wpj, "origin", pixel ? Vec3d { 0, -150, 0 } : Vec3d { 0, 0, 0 });
        Vec3d n = ReadVec3(wpj, "plane", { 0, 1, 0 });
        Vec3d f = ReadVec3(wpj, "forward", { 0, 0, 1 });
        const auto size = ReadVec2(wpj, "size", { 200.0, 200.0 });
        if (n.norm() > 0.0) n.normalize();
        if (f.norm() > 0.0) f.normalize();
        Vec3d r = n.cross(f);
        if (r.norm() > 0.0) r.normalize();
        Vec3d up = r.cross(n);
        if (up.norm() > 0.0) up.normalize();
        const double half_x = size[0] * 0.5;
        const double half_y = size[1] * 0.5;
        return [=](const ParticleInfo& info) {
            Vec3d centre = origin, normal = n, along_r = r, along_f = up;
            if (respond.LocksToControlpoint()) {
                if (const auto* point = PointOf(info.controlpoints, respond.controlpoint)) {
                    centre = point->offset;
                    if (point->has_rotation) {
                        normal  = point->rotation * normal;
                        along_r = point->rotation * along_r;
                        along_f = point->rotation * along_f;
                    }
                }
            }
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const Vec3d  rel  = PM::GetPos(p).cast<double>() - centre;
                const double d    = rel.dot(normal);
                const double was  = (p.prev_position.cast<double>() - centre).dot(normal);
                if (! (was > 0.0 && d <= 0.0)) continue;
                if (! (std::abs(rel.dot(along_f)) < half_y && std::abs(rel.dot(along_r)) < half_x)) continue;
                PM::Move(p, normal * (-1.05 * d));
                respond(p, normal);
            }
        };
    }
    if (name == "collisionmodel") {
        // Kernel sub_1402508C0 (F-D13.md): capsules of the linked layer, rebuilt
        // every step; particles in groups of four, one slice of them a step when a
        // system holds 10000 or more (slice = step % (count / 10000 + 1)). The last
        // capsule a particle is inside pushes it out to its surface.
        const auto respond = CollisionResponse::Read(wpj);
        auto source = std::make_shared<ParticleCollisionModelSource>();
        if (ctx.links) ctx.links->slots.push_back({ ParticleLayerLinks::Kind::CollisionModel, source });
        return [respond, source](const ParticleInfo& info) {
            if (! source->fill) return;
            auto& capsules = source->capsules;
            capsules.clear();
            source->fill(capsules);
            if (capsules.empty()) return;
            const linalg::Matrix3d linear = info.scene_to_local.topLeftCorner<3, 3>();
            const double scale = std::cbrt(std::abs(linear.determinant()));
            for (auto& c : capsules) {
                c.a = TransformPoint(info.scene_to_local, c.a);
                c.b = TransformPoint(info.scene_to_local, c.b);
                c.radius *= scale;
            }
            const std::size_t count  = info.particles.size();
            const std::size_t slices = count / 10000 + 1;
            const std::size_t slice  = info.step % slices;
            for (std::size_t i = 0; i < count; ++i) {
                if ((i / 4) % slices != slice) continue;
                auto& p = info.particles[i];
                if (! PM::LifetimeOk(p)) continue;
                const Vec3d pos = PM::GetPos(p).cast<double>();
                const ParticleCapsule* hit = nullptr;
                Vec3d                  hit_diff;
                for (const auto& c : capsules) {
                    const Vec3d  seg = c.b - c.a;
                    const double len = seg.norm();
                    const Vec3d  axis = len > 0.0 ? Vec3d(seg / len) : Vec3d::Zero();
                    const double t = std::clamp((pos - c.a).dot(axis), 0.0, len);
                    const Vec3d  diff = pos - (c.a + axis * t);
                    if (diff.norm() < c.radius) {
                        hit      = &c;
                        hit_diff = diff;
                    }
                }
                if (hit == nullptr) continue;
                const double dist = hit_diff.norm();
                if (! (dist > 0.0)) continue;
                const Vec3d normal = hit_diff / dist;
                PM::Move(p, normal * -(dist - hit->radius));
                respond(p, normal);
            }
        };
    }
    LogInertOnce("operator", name);
    return inert;
}

ParticleEmittOp WPParticleParser::genParticleEmittOp(
    const wpscene::Emitter& wpe, bool sort,
    std::shared_ptr<const wpscene::ParticleInstanceoverride> override,
    std::function<audio::AudioSpectrumSnapshot()>            audio_spectrum,
    std::shared_ptr<ParticleSpawnContext>                    spawn,
    std::shared_ptr<ParticleLayerLinks>                      links) {
    std::shared_ptr<const float> count;
    if (override) count = std::shared_ptr<const float>(override, &override->count);

    if (wpe.name == "boxrandom") {
        ParticleBoxEmitterArgs a;
        a.directions      = wpe.directions;
        a.minDistance     = wpe.distancemin;
        a.maxDistance     = wpe.distancemax;
        a.emitSpeed       = wpe.rate;
        a.orgin           = wpe.origin;
        a.one_per_frame   = wpe.flags[wpscene::Emitter::FlagEnum::one_per_frame];
        a.sort            = sort;
        a.instantaneous   = wpe.instantaneous;
        a.minSpeed        = wpe.speedmin;
        a.maxSpeed        = wpe.speedmax;
        a.controlpoint    = wpe.controlpoint;
        a.countMultiplier = std::move(count);
        a.audioResponse   = MakeAudioResponse(wpe, audio_spectrum);
        a.timing          = TimingOf(wpe);
        a.spawn           = std::move(spawn);
        return ParticleBoxEmitterArgs::MakeEmittOp(std::move(a));
    }
    if (wpe.name == "sphererandom") {
        ParticleSphereEmitterArgs a;
        a.directions      = wpe.directions;
        a.minDistance     = wpe.distancemin[0];
        a.maxDistance     = wpe.distancemax[0];
        a.emitSpeed       = wpe.rate;
        a.orgin           = wpe.origin;
        a.sign            = wpe.sign;
        a.one_per_frame   = wpe.flags[wpscene::Emitter::FlagEnum::one_per_frame];
        a.sort            = sort;
        a.instantaneous   = wpe.instantaneous;
        a.minSpeed        = wpe.speedmin;
        a.maxSpeed        = wpe.speedmax;
        a.controlpoint    = wpe.controlpoint;
        a.countMultiplier = std::move(count);
        a.audioResponse   = MakeAudioResponse(wpe, audio_spectrum);
        a.timing          = TimingOf(wpe);
        a.cone            = wpe.cone;
        a.spawn           = std::move(spawn);
        return ParticleSphereEmitterArgs::MakeEmittOp(std::move(a));
    }
    if (wpe.name == "layerimage") {
        auto link = std::make_shared<ParticleLayerImageLink>();
        if (links) links->slots.push_back({ ParticleLayerLinks::Kind::EmitterImage, nullptr, link });
        auto context = spawn ? spawn : std::make_shared<ParticleSpawnContext>();
        ParticlePlacedEmitterArgs a;
        a.emitSpeed = wpe.rate;
        a.instantaneous = wpe.instantaneous;
        a.one_per_frame = wpe.flags[wpscene::Emitter::FlagEnum::one_per_frame];
        a.sort = sort;
        a.controlpoint = wpe.controlpoint;
        a.countMultiplier = std::move(count);
        a.audioResponse = MakeAudioResponse(wpe, audio_spectrum);
        a.timing = TimingOf(wpe);
        a.spawn = spawn;
        a.particle = [link, context, wpe]() -> std::optional<Particle> {
            if (! link->source || link->source->samples.empty()) return std::nullopt;
            const auto& source = *link->source;
            const auto at = Random::get<std::size_t>(0, source.samples.size() - 1);
            const auto& sample = source.samples[at];
            Vec3d offset = Vec3d::Zero();
            if (wpe.flags[wpscene::Emitter::FlagEnum::image_offsets]) {
                for (int axis = 0; axis < 3; ++axis)
                    offset[axis] = Lerp(wpe.offsetmin[axis], wpe.offsetmax[axis], Random::get(0.0, 1.0));
            }
            const Vec3d local = source.LocalPosition(sample, offset);
            const Vec3d world = TransformPoint(source.world, local);
            Particle particle;
            PM::MoveTo(particle, TransformPoint(context->scene_to_local, world));
            if (wpe.flags[wpscene::Emitter::FlagEnum::image_colour]) {
                PM::InitColor(particle, sample.colour[0] / 255.0, sample.colour[1] / 255.0,
                               sample.colour[2] / 255.0);
            }
            const double frame_time = context->scene_frame_time > 0.0 ? context->scene_frame_time : context->frame_time;
            if (wpe.flags[wpscene::Emitter::FlagEnum::image_motion] && frame_time > 0.0) {
                const Vec3d motion = (world - TransformPoint(source.previous_world, local)) / frame_time;
                PM::InitVelocity(particle, context->scene_to_local.topLeftCorner<3, 3>() * motion *
                                          Lerp(wpe.speedmin, wpe.speedmax, Random::get(0.0, 1.0)));
            }
            return particle;
        };
        auto emitter = ParticlePlacedEmitterArgs::MakeEmittOp(std::move(a));
        return [emitter = std::move(emitter), link, context,
                refresh = wpe.flags[wpscene::Emitter::FlagEnum::image_refresh]]
            (std::vector<Particle>& particles, std::vector<ParticleInitOp>& initializers,
             uint32_t maxcount, double dt, std::span<const ParticleControlpoint> points) mutable {
            if (link->source) link->source->Prepare(context->layer_time, refresh);
            emitter(particles, initializers, maxcount, dt, points);
        };
    }
    // Other unrecognised records are inert.
    LogInertOnce("emitter", wpe.name);
    return [](std::vector<Particle>&, std::vector<ParticleInitOp>&, uint32_t, double,
              std::span<const ParticleControlpoint>) {};
}
