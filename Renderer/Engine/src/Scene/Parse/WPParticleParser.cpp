// Clean-room implementation from the WallpaperMachine spec e4-particle-simulation.md; written without access to the original source.
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

/// Control point numbers: 0..6 name themselves, anything else names the last.
std::size_t ClampPoint(int index) {
    return (index >= 0 && index <= 6) ? static_cast<std::size_t>(index) : 7u;
}

const ParticleControlpoint* PointOf(std::span<const ParticleControlpoint> points, int index) {
    const std::size_t i = ClampPoint(index);
    return i < points.size() ? &points[i] : nullptr;
}

double FiniteOr(double value, double fallback) { return std::isfinite(value) ? value : fallback; }

// --- reference gradient noise (spec 3.12) ---------------------------------------

constexpr std::array<std::uint8_t, 256> kPermutation = {
    151, 160, 137, 91,  90,  15,  131, 13,  201, 95,  96,  53,  194, 233, 7,   225, 140, 36,  103,
    30,  69,  142, 8,   99,  37,  240, 21,  10,  23,  190, 6,   148, 247, 120, 234, 75,  0,   26,
    197, 62,  94,  252, 219, 203, 117, 35,  11,  32,  57,  177, 33,  88,  237, 149, 56,  87,  174,
    20,  125, 136, 171, 168, 68,  175, 74,  165, 71,  134, 139, 48,  27,  166, 77,  146, 158, 231,
    83,  111, 229, 122, 60,  211, 133, 230, 220, 105, 92,  41,  55,  46,  245, 40,  244, 102, 143,
    54,  65,  25,  63,  161, 1,   216, 80,  73,  209, 76,  132, 187, 208, 89,  18,  169, 200, 196,
    135, 130, 116, 188, 159, 86,  164, 100, 109, 198, 173, 186, 3,   64,  52,  217, 226, 250, 124,
    123, 5,   202, 38,  147, 118, 126, 255, 82,  85,  212, 207, 206, 59,  227, 47,  16,  58,  17,
    182, 189, 28,  42,  223, 183, 170, 213, 119, 248, 152, 2,   44,  154, 163, 70,  221, 153, 101,
    155, 167, 43,  172, 9,   129, 22,  39,  253, 19,  98,  108, 110, 79,  113, 224, 232, 178, 185,
    112, 104, 218, 246, 97,  228, 251, 34,  242, 193, 238, 210, 144, 12,  191, 179, 162, 241, 81,
    51,  145, 235, 249, 14,  239, 107, 49,  192, 214, 31,  181, 199, 106, 157, 184, 84,  204, 176,
    115, 121, 50,  45,  127, 4,   150, 254, 138, 236, 205, 93,  222, 114, 67,  29,  24,  72,  243,
    141, 128, 195, 78,  66,  215, 61,  156, 180
};

int Hash(int i) { return kPermutation[static_cast<std::size_t>(i & 255)]; }

double Fade(double t) { return t * t * t * (t * (t * 6.0 - 15.0) + 10.0); }

double Gradient(int hash, double x, double y, double z) {
    const int    h = hash & 15;
    const double u = h < 8 ? x : y;
    const double v = h < 4 ? y : ((h == 12 || h == 14) ? x : z);
    return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v);
}

/// Perlin's improved noise in three dimensions: zero at lattice points, within
/// -1..1, period 256 on each axis.
double Noise3(double x, double y, double z) {
    const double fx = std::floor(x), fy = std::floor(y), fz = std::floor(z);
    // Reduce in double first so a huge coordinate cannot overflow the int cast.
    const int cx = static_cast<int>(std::fmod(fx, 256.0));
    const int cy = static_cast<int>(std::fmod(fy, 256.0));
    const int cz = static_cast<int>(std::fmod(fz, 256.0));
    const int X = cx & 255, Y = cy & 255, Z = cz & 255;
    x -= fx;
    y -= fy;
    z -= fz;
    const double u = Fade(x), v = Fade(y), w = Fade(z);
    const int    A = Hash(X) + Y, AA = Hash(A) + Z, AB = Hash(A + 1) + Z;
    const int    B = Hash(X + 1) + Y, BA = Hash(B) + Z, BB = Hash(B + 1) + Z;
    return Lerp(
        Lerp(Lerp(Gradient(Hash(AA), x, y, z), Gradient(Hash(BA), x - 1, y, z), u),
             Lerp(Gradient(Hash(AB), x, y - 1, z), Gradient(Hash(BB), x - 1, y - 1, z), u), v),
        Lerp(Lerp(Gradient(Hash(AA + 1), x, y, z - 1), Gradient(Hash(BA + 1), x - 1, y, z - 1), u),
             Lerp(Gradient(Hash(AB + 1), x, y - 1, z - 1),
                  Gradient(Hash(BB + 1), x - 1, y - 1, z - 1), u),
             v),
        w);
}

/// `octaves` layers of noise, frequency doubling and weight halving, divided by
/// the weight sum: within -1..1.
double FractalNoise(double a, double b, int octaves) {
    double sum = 0.0, weights = 0.0, weight = 1.0, frequency = 1.0;
    for (int i = 0; i < octaves; ++i) {
        sum += weight * Noise3(a * frequency, b * frequency, 0.0);
        weights += weight;
        weight *= 0.5;
        frequency *= 2.0;
    }
    return weights > 0.0 ? sum / weights : 0.0;
}

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
        return [=](Particle& p, double) {
            const double life = std::max(Lerp(lo, hi, DrawShaped(exponent)), 0.001);
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
        const OverrideTint tint(ctx.over, ctx.color);
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
        const OverrideTint tint(ctx.over, ctx.color);
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
        const OverrideTint tint(ctx.over, ctx.color);
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
        const double scale     = ReadKey<double>(wpj, "scale", 1.0);
        const double timescale = std::max(ReadKey<double>(wpj, "timescale", 1.0), 1.0e-3);
        const double offset    = ReadKey<double>(wpj, "offset", 0.0);
        const double speed_lo  = ReadKey<double>(wpj, "speedmin", 100.0);
        const double speed_hi  = ReadKey<double>(wpj, "speedmax", 250.0);
        Vec3d forward = ReadVec3(wpj, "forward", { 0, 1, 0 });
        Vec3d right   = ReadVec3(wpj, "right", { 0, 0, 1 });
        forward = forward.norm() > 0.0 ? Vec3d(forward.normalized()) : Vec3d(0, 1, 0);
        right   = right.norm() > 0.0 ? Vec3d(right.normalized()) : Vec3d(0, 0, 1);
        const double half_angle = std::min(std::max(scale, 0.0) * 0.5 * Pi, Pi);

        const auto turn_about = [](const Vec3d& v, const Vec3d& axis, double angle) -> Vec3d {
            const double c = std::cos(angle), s = std::sin(angle);
            return v * c + axis.cross(v) * s + axis * (axis.dot(v) * (1.0 - c));
        };
        const auto random_unit = []() -> Vec3d {
            for (int tries = 0; tries < 8; ++tries) {
                const Vec3d v { Random::get(-1.0, 1.0), Random::get(-1.0, 1.0), Random::get(-1.0, 1.0) };
                if (v.norm() > 1.0e-6) return v.normalized();
            }
            return { 0, 1, 0 };
        };
        // The heading wanders a little from one spawn to the next, so spawns
        // close in time head the same way; a larger timescale slows the walk.
        struct Walk {
            Vec3d heading { 0, 1, 0 };
            bool  started { false };
        } walk;
        return [=](Particle& p, double duration) mutable {
            if (! walk.started) {
                walk.heading = random_unit();
                walk.started = true;
            }
            const double gap   = duration > 0.0 ? duration : 1.0 / 60.0;
            const double sigma = std::sqrt(gap / timescale);
            Vec3d        next  = walk.heading + Vec3d { Random::get(-1.0, 1.0), Random::get(-1.0, 1.0),
                                                 Random::get(-1.0, 1.0) } * (sigma * 1.7);
            walk.heading = next.norm() > 1.0e-9 ? Vec3d(next.normalized()) : random_unit();

            // Squeeze the sphere of headings into the cone around `forward`.
            const double angle = std::acos(std::clamp(walk.heading.dot(forward), -1.0, 1.0));
            Vec3d        axis  = forward.cross(walk.heading);
            Vec3d        dir   = forward;
            if (axis.norm() > 1.0e-9 && half_angle > 0.0) {
                dir = turn_about(forward, axis.normalized(), angle * (half_angle / Pi));
            }
            dir = turn_about(dir, right, offset);
            const double speed = Lerp(speed_lo, speed_hi, Draw01());
            PM::ChangeVelocity(p, through_layer(dir * speed));
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
                FractalNoise(pos.x() * scale, time, octaves),
                FractalNoise(time, pos.y() * scale, octaves),
                FractalNoise(pos.z() * scale, -time, octaves),
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
        // The selector is "<mode><quantity>"; any string outside the table
        // does nothing.
        enum class Quantity { Colour, Opacity, ColourOpacity, Velocity, Size, Rotation, AngularVelocity };
        enum class Mode { Set, Multiply, Add };
        static const std::map<std::string, std::pair<Quantity, Mode>> kSelectors = [] {
            std::map<std::string, std::pair<Quantity, Mode>> table;
            const std::pair<const char*, Quantity> quantities[] = {
                { "color", Quantity::Colour },
                { "opacity", Quantity::Opacity },
                { "coloropacity", Quantity::ColourOpacity },
                { "velocity", Quantity::Velocity },
                { "size", Quantity::Size },
                { "rotation", Quantity::Rotation },
                { "angularvelocity", Quantity::AngularVelocity },
            };
            const std::pair<const char*, Mode> modes[] = { { "set", Mode::Set },
                                                           { "multiply", Mode::Multiply },
                                                           { "add", Mode::Add } };
            for (const auto& [quantity_name, quantity] : quantities) {
                for (const auto& [mode_name, mode] : modes) {
                    // Colour and opacity combine by set or multiply, velocity,
                    // rotation and angular velocity by set or add, size by set
                    // or multiply.
                    const bool scaling = mode == Mode::Multiply;
                    const bool offset  = mode == Mode::Add;
                    const bool scalable = quantity == Quantity::Colour || quantity == Quantity::Opacity ||
                                          quantity == Quantity::ColourOpacity || quantity == Quantity::Size;
                    if ((scaling && ! scalable) || (offset && scalable)) continue;
                    table[std::string(mode_name) + quantity_name] = { quantity, mode };
                }
            }
            return table;
        }();

        const auto chosen = kSelectors.find(ReadKey<std::string>(wpj, "input", "setcolor"));
        if (chosen == kSelectors.end()) return inert;
        const auto [quantity, mode] = chosen->second;
        return [=](Particle& p, double) {
            if (! spawn || spawn->parent == nullptr) return;
            const Particle& parent = *spawn->parent;
            const bool      assign = mode == Mode::Set;
            const bool      scale  = mode == Mode::Multiply;
            const auto take_colour = [&] {
                const Vec3d c = parent.color.cast<double>();
                if (assign) PM::InitColor(p, c.x(), c.y(), c.z());
                else PM::MutiplyInitColor(p, c.x(), c.y(), c.z());
            };
            const auto take_opacity = [&] {
                if (assign) PM::InitAlpha(p, parent.alpha);
                else PM::MutiplyInitAlpha(p, parent.alpha);
            };
            switch (quantity) {
            case Quantity::Colour: take_colour(); break;
            case Quantity::Opacity: take_opacity(); break;
            case Quantity::ColourOpacity:
                take_colour();
                take_opacity();
                break;
            case Quantity::Velocity:
                if (assign) PM::InitVelocity(p, parent.velocity.cast<double>());
                else PM::ChangeVelocity(p, parent.velocity.cast<double>());
                break;
            case Quantity::Size:
                if (scale) PM::MutiplyInitSize(p, static_cast<double>(parent.size) / kParticleSizeOverEngine);
                else PM::InitSize(p, parent.size);
                break;
            case Quantity::Rotation:
                if (assign) p.rotation = parent.rotation;
                else PM::Rotate(p, parent.rotation.cast<double>());
                break;
            case Quantity::AngularVelocity:
                if (assign) p.angularVelocity = parent.angularVelocity;
                else PM::ChangeAngularVelocity(p, parent.angularVelocity.cast<double>());
                break;
            }
        };
    }
    LogInertOnce("initializer", name);
    return inert;
}

ParticleInitOp WPParticleParser::genOverrideInitOp(
    std::shared_ptr<const wpscene::ParticleInstanceoverride> over, ParticleColorDefinition def,
    bool speed_override, bool size_override, bool tint_after_retint) {
    LastFinite lifetime, alpha, size, speed, brightness;
    const OverrideTint tint(over, def);
    return [over = std::move(over), tint, speed_override, size_override, tint_after_retint, lifetime, alpha,
            size, speed, brightness](Particle& p, double) mutable {
        if (! over || ! over->enabled) return;
        // The record is read now, so a property that moved it shows in the next birth.
        const double life = lifetime(over->lifetime);
        p.lifetime        = static_cast<float>(p.lifetime * life);
        p.init.lifetime   = static_cast<float>(p.init.lifetime * life);
        PM::MutiplyInitAlpha(p, alpha(over->alpha));
        if (size_override) PM::MutiplyInitSize(p, size(over->size));
        if (speed_override) PM::MutiplyVelocity(p, speed(over->speed));
        if (const auto flat = tint.FlatTint()) PM::InitColor(p, flat->x(), flat->y(), flat->z());
        // A file with colours had them re-tinted by its initializers and operators;
        // in a scene saved before version 5 the newborn is then multiplied by the
        // override itself, once. Nothing moved (override equal to the file's
        // colour) means no multiply either.
        else if (const auto moved = tint.Shifted(); moved && tint_after_retint)
            PM::MutiplyInitColor(p, moved->target.x(), moved->target.y(), moved->target.z());
        const double glow = brightness(over->brightness);
        if (over->hdr && glow != 1.0) PM::MutiplyInitColor(p, glow, glow, glow);
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

    double Speed() {
        return (speed_applies && over && over->enabled) ? last_speed(over->speed) : 1.0;
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

/// What a surface does to a particle it has put back outside.
void Respond(Particle& p, Collision how, double bounce, const Vec3d& normal) {
    const double along = PM::GetVelocity(p).cast<double>().dot(normal);
    switch (how) {
    case Collision::Bounce: PM::ChangeVelocity(p, normal * (-(1.0 + bounce) * along)); break;
    case Collision::Slide: PM::ChangeVelocity(p, normal * -along); break;
    case Collision::Stop: p.velocity = Vector3f::Zero(); break;
    case Collision::Delete: Remove(p); break;
    }
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
    OverrideReader    reader { ctx.over, ctx.speed_override, ctx.size_override, {}, {} };

    if (name == "movement") {
        const double drag    = ReadKey<double>(wpj, "drag", 0.0);
        const Vec3d  gravity = ReadVec3(wpj, "gravity", { 0, 0, 0 });
        const int    flags   = ReadKey<int32_t>(wpj, "flags", 0);
        return [=](const ParticleInfo& info) mutable {
            const double dt = info.time_pass;
            Vec3d        g  = gravity * reader.Speed();
            if (flags & 1) g = info.world_to_local * g;
            const double keep = 1.0 - std::min(drag * dt, 0.9999999);
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
        return [=](const ParticleInfo& info) mutable {
            const double dt   = info.time_pass;
            const Vec3d  push = force * reader.Speed();
            const double keep = 1.0 - std::min(drag * dt, 0.9999999);
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                PM::AngularAccelerate(p, push, dt);
                PM::RotateByTime(p, dt);
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
        const OverrideTint tint(ctx.over, ctx.color);
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
        return [=](const ParticleInfo& info) {
            for (auto& p : info.particles) {
                const double t = PM::LifetimePos(p);
                if (t <= fade_in) {
                    if (fade_in > 0.0) PM::MutiplyAlpha(p, t / fade_in);
                } else if (t > fade_out) {
                    const double span = 1.0 - fade_out;
                    PM::MutiplyAlpha(p, span > 0.0 ? 1.0 - (t - fade_out) / span : 0.0);
                }
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
            const double dt    = info.time_pass;
            const double level = gate.Level() * reader.Speed();
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const double seed  = p.seed;
                const double phase = seed * (ph_hi - ph_lo) + info.time * timescale;
                const Vec3d  q = (PM::GetPos(p).cast<double>() + Vec3d::Constant(phase)) * scale;
                const Vec3d  field { Noise3(q.x(), q.y(), q.z()), Noise3(q.z(), q.x(), q.y()),
                                     Noise3(q.y(), q.z(), q.x()) };
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
        const LifeEnvelope blend(wpj);
        const AudioGate   gate  = AudioGate::Read(wpj, ctx);
        return [=](const ParticleInfo& info) mutable {
            const auto* point  = PointOf(info.controlpoints, index);
            const Vec3d centre = (point ? point->offset : Vec3d::Zero()) + offset;
            const double dt    = info.time_pass;
            const double level = gate.Level() * reader.Speed();
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                Vec3d d = PM::GetPos(p).cast<double>() - centre;
                if (flags & 1) d -= axis * d.dot(axis);
                const double r = d.norm();
                if (! (r > 1.0e-9)) continue;
                const double t = outer > inner ? std::clamp((r - inner) / (outer - inner), 0.0, 1.0)
                                               : (r >= outer ? 1.0 : 0.0);
                const double speed = level * blend.At(PM::LifetimePos(p)) * Lerp(speed_in, speed_out, t);
                PM::ChangeVelocity(p, d.cross(axis) / r * (speed * dt));
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
        return [=](const ParticleInfo& info) mutable {
            const auto* point  = PointOf(info.controlpoints, index);
            const Vec3d centre = point ? point->offset : Vec3d::Zero();
            const double dt    = info.time_pass;
            const double power = scale * reader.Speed();
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                const Vec3d  pos = PM::GetPos(p).cast<double>();
                const Vec3d  d   = pos - centre;
                const double len = d.norm();
                if (len > 0.0 && len < threshold) {
                    double k = (1.0 - len / threshold) * power * dt;
                    if ((flags & 2) && k > 0.0) k = std::min(k, len);
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
                PM::MutiplyVelocity(p, 1.0 - reduction);
            }
        };
    }
    if (name == "maintaindistancetocontrolpoint") {
        const int    index    = ReadKey<int32_t>(wpj, "controlpoint", 0);
        const double distance = ReadKey<double>(wpj, "distance", pixel ? 200.0 : 1.0);
        const double variable = ReadKey<double>(wpj, "variablestrength", 0.0);
        return [=](const ParticleInfo& info) {
            const auto* point = PointOf(info.controlpoints, index);
            if (point == nullptr) return;
            const Vec3d ride   = point->offset - point->prev_offset;
            const double amount = variable == 0.0 ? 1.0 : std::clamp(variable * info.time_pass, 0.0, 1.0);
            for (auto& p : info.particles) {
                if (! PM::LifetimeOk(p)) continue;
                PM::Move(p, ride);
                const Vec3d  rel = PM::GetPos(p).cast<double>() - point->offset;
                const double len = rel.norm();
                if (len > 0.0) PM::Move(p, rel * ((distance / len - 1.0) * amount));
            }
        };
    }
    if (name == "maintaindistancebetweencontrolpoints") {
        const int first = ReadKey<int32_t>(wpj, "controlpointstart", 0);
        const int last  = ReadKey<int32_t>(wpj, "controlpointend", 1);
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
                PM::Move(p, slide + now * std::clamp(along, 0.0, 1.0) - was * along);
            }
        };
    }
    if (name == "collisionplane" || name == "collisionsphere") {
        const bool   sphere   = name == "collisionsphere";
        const int    index    = ReadKey<int32_t>(wpj, "controlpoint", 0);
        const int    flags    = ReadKey<int32_t>(wpj, "flags", 0);
        const Vec3d  origin   = ReadVec3(wpj, "origin", pixel ? Vec3d { 0, -200, 0 } : Vec3d { 0, 0, 0 });
        const double distance = ReadKey<double>(wpj, "distance", pixel ? -150.0 : 0.0);
        const double radius   = ReadKey<double>(wpj, "radius", pixel ? 50.0 : 1.0);
        const double bounce   = ReadKey<double>(wpj, "bouncefactor", 0.5);
        const Collision how   = CollisionOf(ReadKey<std::string>(wpj, "collisionbehavior", "bounce"));
        Vec3d        plane    = ReadVec3(wpj, "plane", { 0, 1, 0 });
        plane = plane.norm() > 0.0 ? Vec3d(plane.normalized()) : Vec3d::Zero();
        return [=](const ParticleInfo& info) {
            const auto* point = (flags & 1) ? PointOf(info.controlpoints, index) : nullptr;
            if (sphere) {
                const Vec3d centre = point ? point->offset : origin;
                for (auto& p : info.particles) {
                    if (! PM::LifetimeOk(p)) continue;
                    const Vec3d  rel = PM::GetPos(p).cast<double>() - centre;
                    const double len = rel.norm();
                    if (! (len > 0.0) || len - radius >= 0.0) continue;
                    const Vec3d normal = rel / len;
                    PM::MoveTo(p, centre + normal * radius);
                    Respond(p, how, bounce, normal);
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
                    Respond(p, how, bounce, normal);
                }
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
    std::shared_ptr<ParticleSpawnContext>                    spawn) {
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
    // Any other emitter (one stock file has `layerimage`) never emits.
    LogInertOnce("emitter", wpe.name);
    return [](std::vector<Particle>&, std::vector<ParticleInitOp>&, uint32_t, double,
              std::span<const ParticleControlpoint>) {};
}
