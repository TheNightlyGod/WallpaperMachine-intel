// Clean-room implementation from the WallpaperMachine spec e4-particle-simulation.md; written without access to the original source.
#include "WPParticleRawGener.h"

#include <algorithm>
#include <cmath>
#include <array>
#include <cstring>
#include <vector>
#include <limits>

#include "Utils/Linalg.hpp"

#include "Core/Literals.hpp"
#include "SpecTexs.hpp"
#include "ParticleModify.h"
#include "ParticleSystem.h"

#include "Utils/Logging.h"

using namespace wallpaper;
using namespace wallpaper::linalg;

namespace
{

namespace PM = ParticleModify;

/// The corner of each of a quad's four vertices in the texture: vertices 0..3.
constexpr std::array<std::array<float, 2>, 4> kCorners { { { 0.0f, 1.0f },
                                                           { 1.0f, 1.0f },
                                                           { 1.0f, 0.0f },
                                                           { 0.0f, 0.0f } } };

constexpr std::size_t kSpriteThin  = 16;
constexpr std::size_t kSpriteThick = 20;
constexpr std::size_t kRopeThin    = 24;
constexpr std::size_t kRopeThick   = 28;
constexpr std::size_t kMaxFloatsPerVertex = kRopeThick;

/// Where a mesh is written to and how much of it may be.
struct Target {
    SceneVertexArray* vertices { nullptr };
    SceneIndexArray*  indices { nullptr };
    std::size_t       floats { 0 };      // per vertex
    uint64_t          capacity { 0 };    // quads the vertices and the indices both hold
    uint64_t          quads { 0 };       // quads written so far
    uint64_t          wanted { 0 };      // quads asked for, written or not
    bool              thick { false };
};

/// Stores one quad of four vertices, `data` holding `floats` for each.
void StoreQuad(Target& t, const float* data) {
    t.vertices->SetVertexs(static_cast<std::size_t>(t.quads) * 4,
                           std::span<const float>(data, t.floats * 4));
    ++t.quads;
}

/// Extends the index data to name `quads` quads: vertices (0,1,3) and (1,2,3) of
/// each. Written once and only ever extended.
void ExtendIndices(SceneIndexArray& indices, uint64_t quads) {
    const bool wide = indices.Width() == SceneIndexWidth::UInt32;
    const uint64_t per_quad = wide ? 6u : 3u;
    uint64_t       written  = indices.DataCount() / per_quad;
    for (; written < quads; ++written) {
        const uint64_t base = written * 4;
        if (wide) {
            const std::array<uint32_t, 6> pattern { static_cast<uint32_t>(base),
                                                    static_cast<uint32_t>(base + 1),
                                                    static_cast<uint32_t>(base + 3),
                                                    static_cast<uint32_t>(base + 1),
                                                    static_cast<uint32_t>(base + 2),
                                                    static_cast<uint32_t>(base + 3) };
            indices.Assign(static_cast<std::size_t>(written * 6), pattern);
        } else {
            const std::array<uint16_t, 6> pattern { static_cast<uint16_t>(base),
                                                    static_cast<uint16_t>(base + 1),
                                                    static_cast<uint16_t>(base + 3),
                                                    static_cast<uint16_t>(base + 1),
                                                    static_cast<uint16_t>(base + 2),
                                                    static_cast<uint16_t>(base + 3) };
            indices.AssignHalf(static_cast<std::size_t>(written * 6), pattern);
        }
    }
}

double SmoothStep(double t) { return t * t * (3.0 - 2.0 * t); }

// --- sprites -----------------------------------------------------------------------

void WriteSprite(Target& t, const Particle& p, const Vector3d& anchor, float animation) {
    std::array<float, kMaxFloatsPerVertex * 4> quad;
    const float half = p.size / kParticleSizeOverEngine;
    for (std::size_t v = 0; v < 4; ++v) {
        float* out = quad.data() + v * t.floats;
        out[0]     = static_cast<float>(p.position.x() + anchor.x());
        out[1]     = static_cast<float>(p.position.y() + anchor.y());
        out[2]     = static_cast<float>(p.position.z() + anchor.z());
        out[3]     = 0.0f;
        out[4]     = kCorners[v][0];
        out[5]     = kCorners[v][1];
        out[6]     = p.rotation.z();
        out[7]     = half;
        out[8]     = p.color.x();
        out[9]     = p.color.y();
        out[10]    = p.color.z();
        out[11]    = p.alpha;
        std::size_t next = 12;
        if (t.thick) {
            out[12] = p.velocity.x();
            out[13] = p.velocity.y();
            out[14] = p.velocity.z();
            out[15] = animation;
            next    = 16;
        }
        out[next]     = p.rotation.x();
        out[next + 1] = p.rotation.y();
        out[next + 2] = 0.0f;
        out[next + 3] = 0.0f;
    }
    StoreQuad(t, quad.data());
}

void GenerateSprites(std::span<const std::unique_ptr<ParticleInstance>> instances, Target& t,
                     ParticleRawGenSpecOp& spec) {
    for (const auto& instance : instances) {
        if (! instance || instance->IsNoLiveParticle()) continue;
        const auto& bound  = instance->GetBoundedData();
        const Vector3d anchor { bound.pos.x(), bound.pos.y(), bound.pos.z() };
        for (const auto& p : instance->Particles()) {
            if (! PM::LifetimeOk(p)) continue;
            ++t.wanted;
            if (t.quads >= t.capacity) continue;
            float animation = p.lifetime;
            if (spec) spec(p, ParticleRawGenSpec { &animation });
            WriteSprite(t, p, anchor, animation);
        }
    }
}

// --- ropes -------------------------------------------------------------------------

/// A station on a ribbon: where it lies and how the ribbon looks there.
struct Station {
    Vector3d at;
    Vector3d tint;
    double   opacity;
    double   radius;
};

Station StationOf(const Particle& p, const Vector3d& anchor) {
    return { Vector3d { p.position.x() + anchor.x(), p.position.y() + anchor.y(),
                        p.position.z() + anchor.z() },
             Vector3d { p.color.x(), p.color.y(), p.color.z() }, p.alpha,
             static_cast<double>(p.size) / kParticleSizeOverEngine };
}

/// The station a fraction `s` of the way from `a` to `b`.
Station Between(const Station& a, const Station& b, double s) {
    return { Vector3d(a.at + (b.at - a.at) * s), Vector3d(a.tint + (b.tint - a.tint) * s),
             a.opacity + (b.opacity - a.opacity) * s, a.radius + (b.radius - a.radius) * s };
}

struct StripParams {
    uint32_t pieces { 1 };     // pieces drawn between two connected stations
    float    uv_scale { 1.0f };
    bool     smoothing { false };
    float    length { 0.0f };  // the strip's length before the uv scale is applied
};

/// Everything the vertex data of one ribbon piece is made of.
struct PieceData {
    Station  head;            // where the piece starts
    Station  tail;            // where it ends
    Vector3d handle_head;     // first control vector
    Vector3d handle_tail;     // second control vector
    float    encoded_length;  // the strip's encoded length
    float    along;           // the piece's position along the strip
};

/// Fills a vertex front to back in groups of four floats.
class GroupWriter {
public:
    explicit GroupWriter(float* first) : m_next(first) {}

    void Group(float a, float b, float c, float d) {
        m_next[0] = a;
        m_next[1] = b;
        m_next[2] = c;
        m_next[3] = d;
        m_next += 4;
    }
    void Group(const Vector3d& xyz, double w) {
        Group(static_cast<float>(xyz.x()), static_cast<float>(xyz.y()), static_cast<float>(xyz.z()),
              static_cast<float>(w));
    }

private:
    float* m_next;
};

void WritePiece(Target& t, const PieceData& piece) {
    std::array<float, kMaxFloatsPerVertex * 4> quad;
    for (std::size_t corner = 0; corner < kCorners.size(); ++corner) {
        GroupWriter vertex(quad.data() + corner * t.floats);
        vertex.Group(piece.head.at, piece.head.radius);
        vertex.Group(piece.tail.at, piece.encoded_length);
        vertex.Group(piece.handle_head, piece.along);
        vertex.Group(piece.handle_tail, piece.tail.radius);
        if (t.thick) vertex.Group(piece.tail.tint, piece.tail.opacity);
        vertex.Group(kCorners[corner][0], kCorners[corner][1], 0.0f, 0.0f);
        vertex.Group(piece.head.tint, piece.head.opacity);
    }
    StoreQuad(t, quad.data());
}

/// The heading of a strip at station `i`: the difference of the stations on
/// either side, an end station using itself for the side it lacks.
Vector3d HeadingAt(const Station* stations, std::size_t count, std::size_t i) {
    const std::size_t before = i > 0 ? i - 1 : i;
    const std::size_t after  = std::min(i + 1, count - 1);
    return stations[after].at - stations[before].at;
}

/// Writes the pieces of one strip: each pair of consecutive stations becomes
/// `pieces` pieces along a smooth curve through them, spaced by smoothstep.
void WriteStrip(Target& t, const Station* stations, std::size_t count, const StripParams& params) {
    if (count < 2) return;
    const uint32_t pieces    = std::max<uint32_t>(params.pieces, 1);
    const double   total     = static_cast<double>(count - 1) * pieces;
    const float    encoded   = EncodeRopeTrailLength(params.length, params.uv_scale);
    const bool     smooth_uv = params.smoothing && total > 1.0;

    for (std::size_t i = 0; i + 1 < count; ++i) {
        const Station& first = stations[i];
        const Station& last  = stations[i + 1];
        const Vector3d chord = last.at - first.at;
        // No piece between coincident stations; the strip's counting goes on.
        if (chord.norm() < 1.0e-6) continue;

        Vector3d lead  = HeadingAt(stations, count, i);
        Vector3d trail = HeadingAt(stations, count, i + 1);
        if (lead.norm() < 1.0e-12) lead = chord;
        if (trail.norm() < 1.0e-12) trail = chord;
        const Vector3d inner_first = first.at + lead * 0.15;
        const Vector3d inner_last  = last.at - trail * 0.15;

        const auto point_at = [&](double s) -> Vector3d {
            const double u = 1.0 - s;
            return first.at * (u * u * u) + inner_first * (3.0 * u * u * s) +
                   inner_last * (3.0 * u * s * s) + last.at * (s * s * s);
        };
        const auto slope_at = [&](double s) -> Vector3d {
            const double u = 1.0 - s;
            return (inner_first - first.at) * (3.0 * u * u) + (inner_last - inner_first) * (6.0 * u * s) +
                   (last.at - inner_last) * (3.0 * s * s);
        };

        for (uint32_t j = 0; j < pieces; ++j) {
            ++t.wanted;
            if (t.quads >= t.capacity) continue;
            const bool   at_first = j == 0;
            const bool   at_last  = j + 1 == pieces;
            const double s0 = at_first ? 0.0 : SmoothStep(static_cast<double>(j) / pieces);
            const double s1 = at_last ? 1.0 : SmoothStep(static_cast<double>(j + 1) / pieces);

            PieceData piece;
            piece.head = Between(first, last, s0);
            piece.tail = Between(first, last, s1);
            if (at_first) piece.head.at = first.at; else piece.head.at = point_at(s0);
            if (at_last) piece.tail.at = last.at; else piece.tail.at = point_at(s1);
            // The piece's own tangents, scaled so the shader's curve through its
            // two ends is the stretch of the pair's curve between s0 and s1.
            const double span = (s1 - s0) / 0.45;
            piece.handle_head = piece.tail.at - slope_at(s0) * span;
            piece.handle_tail = piece.head.at + slope_at(s1) * span;
            const double index = static_cast<double>(i) * pieces + j;
            piece.along        = static_cast<float>(smooth_uv ? SmoothStep(index / total) * total : index);
            piece.encoded_length = encoded;
            WritePiece(t, piece);
        }
    }
}

void GenerateRopes(std::span<const std::unique_ptr<ParticleInstance>> instances, Target& t,
                   const ParticleRenderScale& scale) {
    thread_local std::vector<Station> strip;
    StripParams params;
    params.pieces    = std::clamp<uint32_t>(scale.rope_subdivision, 1u, 64u);
    params.uv_scale  = RopeUvScaleOrOne(scale.uv_scale);
    params.smoothing = scale.uv_smoothing && ! scale.uv_scrolling;

    for (const auto& instance : instances) {
        if (! instance || instance->IsNoLiveParticle()) continue;
        const auto&    bound = instance->GetBoundedData();
        const Vector3d anchor { bound.pos.x(), bound.pos.y(), bound.pos.z() };
        strip.clear();
        for (const auto& p : instance->Particles()) {
            if (PM::LifetimeOk(p)) strip.push_back(StationOf(p, anchor));
        }
        if (strip.size() < 2) continue;
        const double stations = static_cast<double>(strip.size() - 1) * params.pieces + 1.0;
        params.length         = scale.uv_scrolling ? static_cast<float>(t.capacity) + 1.0f
                                                   : static_cast<float>(stations);
        WriteStrip(t, strip.data(), strip.size(), params);
    }
}

void GenerateRopeTrails(std::span<const std::unique_ptr<ParticleInstance>> instances, Target& t,
                        const ParticleRenderScale& scale) {
    thread_local std::vector<Station> strip;
    StripParams params;
    params.pieces    = std::clamp<uint32_t>(scale.rope_subdivision, 1u, 64u);
    params.uv_scale  = RopeUvScaleOrOne(scale.uv_scale);
    params.smoothing = false;
    const double fraction = std::clamp(static_cast<double>(scale.trail_fraction), 0.0, 1.0);

    for (const auto& instance : instances) {
        if (! instance || instance->IsNoLiveParticle()) continue;
        const auto&    bound  = instance->GetBoundedData();
        const Vector3d anchor { bound.pos.x(), bound.pos.y(), bound.pos.z() };
        const auto     particles = instance->Particles();
        const auto     trails    = instance->Trails();
        for (std::size_t slot = 0; slot < particles.size() && slot < trails.size(); ++slot) {
            const Particle& p = particles[slot];
            if (! PM::LifetimeOk(p)) continue;
            const ParticleTrailHistory& history = trails[slot];
            const uint32_t              held    = history.Count();
            if (held == 0) continue;

            // The particle as drawn now, then its recorded points newest to oldest.
            strip.clear();
            const Station head = StationOf(p, anchor);
            strip.push_back(head);
            for (uint32_t age = 0; age < held; ++age) {
                Station recorded = head;
                const auto& where = history.At(age).position;
                recorded.at       = Vector3d { where.x(), where.y(), where.z() };
                strip.push_back(recorded);
            }
            // A full history gives its oldest point up to the newer one as the
            // period goes by, so the tail shrinks by what the head grew.
            if (held == history.Capacity() && held >= 2) {
                Station&       oldest = strip[strip.size() - 1];
                const Station& newer  = strip[strip.size() - 2];
                oldest.at += (newer.at - oldest.at) * fraction;
            }

            const double pieces     = params.pieces;
            const double capacity   = static_cast<double>(history.Capacity());
            const bool   subdivided = params.pieces != 1;
            const double recorded_count = static_cast<double>(held);
            double       units;
            if (scale.uv_scrolling) {
                units = subdivided ? capacity * pieces : capacity;
            } else {
                units = subdivided ? recorded_count * pieces + 1.0 : recorded_count;
            }
            params.length = static_cast<float>(units);
            WriteStrip(t, strip.data(), strip.size(), params);
        }
    }
}

} // namespace

void WPParticleRawGener::GenGLData(std::span<const std::unique_ptr<ParticleInstance>> instances,
                                   SceneMesh& mesh, ParticleRawGenSpecOp& specOp,
                                   ParticleRenderScale render_scale,
                                   ParticleOverflowFlags& overflow_flags) {
    if (mesh.VertexCount() == 0 || mesh.IndexCount() == 0) return;
    auto& vertices = mesh.GetVertexArray(0);
    auto& indices  = mesh.GetIndexArray(0);

    const bool rope_trail = vertices.GetOption(WE_PRENDER_ROPETRAIL);
    const bool rope       = rope_trail || vertices.GetOption(WE_PRENDER_ROPE);
    const bool thick      = vertices.GetOption(WE_CB_THICK_FORMAT);
    const std::size_t expected = rope ? (thick ? kRopeThick : kRopeThin)
                                      : (thick ? kSpriteThick : kSpriteThin);
    if (vertices.OneSize() != expected) {
        LOG_ERROR("particle mesh has %zu floats per vertex where its renderer writes %zu; nothing "
                  "is drawn",
                  static_cast<std::size_t>(vertices.OneSize()), expected);
        indices.SetDrawIndexCount(0);
        return;
    }

    Target target;
    target.vertices = &vertices;
    target.indices  = &indices;
    target.floats   = expected;
    target.thick    = thick;
    target.capacity = std::min<uint64_t>(indices.QuadCapacity(), vertices.CapacitySize() / (expected * 4));

    if (rope_trail) GenerateRopeTrails(instances, target, render_scale);
    else if (rope) GenerateRopes(instances, target, render_scale);
    else GenerateSprites(instances, target, specOp);

    // What did not fit is dropped and said once; the latch clears when the
    // count fits again.
    if (target.wanted > target.capacity) {
        if (rope) {
            if (! overflow_flags.rope_capacity) {
                overflow_flags.rope_capacity = true;
                LOG_ERROR("rope needs %llu pieces but its mesh holds %llu; the rest are not drawn",
                          static_cast<unsigned long long>(target.wanted),
                          static_cast<unsigned long long>(target.capacity));
            }
        } else if (! overflow_flags.index) {
            overflow_flags.index = true;
            LOG_ERROR("particles need %llu quads but the mesh holds %llu; the rest are not drawn",
                      static_cast<unsigned long long>(target.wanted),
                      static_cast<unsigned long long>(target.capacity));
        }
    } else {
        if (rope && target.wanted < target.capacity) overflow_flags.rope_capacity = false;
        if (! rope) overflow_flags.index = false;
    }

    uint64_t draw = 0;
    if (! CheckedMulU64(target.quads, 6, draw)) {
        indices.SetDrawIndexCount(0);
        return;
    }
    ExtendIndices(indices, target.quads);
    indices.SetDrawIndexCount(static_cast<std::size_t>(draw));
}
