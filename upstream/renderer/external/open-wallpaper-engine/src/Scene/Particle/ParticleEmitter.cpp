#include "ParticleEmitter.h"
#include "ParticleModify.h"
#include "Utils/Algorism.h"
#include "Utils/Logging.h"
#include "Utils/Algorism.h"
#include "Core/Random.hpp"

#include <Eigen/src/Core/Matrix.h>
#include <random>
#include <array>
#include <tuple>
#include <cmath>
#include <cstring>

using namespace wallpaper;

typedef std::function<Particle()> GenParticleOp;
typedef std::function<Particle()> SpwanOp;

namespace
{

inline std::tuple<u32, bool> FindLastParticle(std::span<const Particle> ps, u32 last) {
    for (u32 i = last; i < ps.size(); i++) {
        if (! ParticleModify::LifetimeOk(ps[i])) return { i, true };
    }
    return { 0, false };
}

inline u32 GetEmitNum(double& timer, double speed) {
    if (speed <= 0.0) return 0;
    const double emitDur = 1.0 / speed;
    if (emitDur > timer) return 0;
    u32 num = static_cast<u32>((timer / emitDur) + 1.0e-9);
    timer -= static_cast<double>(num) * emitDur;
    if (timer < 1.0e-9) timer = 0;
    return num;
}

inline u32 Emitt(std::vector<Particle>& particles, u32 num, u32 maxcount, bool sort,
                 SpwanOp Spwan) {
    u32  lastPartcle = 0;
    bool has_dead    = true;
    u32  i           = 0;

    for (i = 0; i < num; i++) {
        if (has_dead) {
            auto [r1, r2] = FindLastParticle(particles, lastPartcle);
            lastPartcle   = r1;
            has_dead      = r2;
        }
        if (has_dead) {
            particles[lastPartcle] = Spwan();

        } else {
            if (maxcount == particles.size()) break;
            particles.push_back(Spwan());
        }
    }

    if (sort) {
        // old << new << dead, stable within each bucket. Three linear passes
        // into scratch instead of a sort; the order is the same one
        // stable_sort produced.
        thread_local std::vector<Particle> scratch;
        scratch.clear();
        scratch.reserve(particles.size());
        for (const auto& particle : particles) {
            if (ParticleModify::LifetimeOk(particle) && ! ParticleModify::IsNew(particle)) {
                scratch.push_back(particle);
            }
        }
        for (const auto& particle : particles) {
            if (ParticleModify::LifetimeOk(particle) && ParticleModify::IsNew(particle)) {
                scratch.push_back(particle);
            }
        }
        for (const auto& particle : particles) {
            if (! ParticleModify::LifetimeOk(particle)) scratch.push_back(particle);
        }
        particles.swap(scratch);
    }

    return i + 1;
}

inline Particle Spwan(GenParticleOp gen, std::vector<ParticleInitOp>& inis, double duration) {
    auto particle = gen();
    // One draw per particle. Operators that vary a particle against its
    // neighbours (oscillators, turbulence) and the sprite-sheet frame of a
    // `randomframe` particle read this value, as Wallpaper Engine keeps a
    // single random per particle for all of them. A function of the spawn
    // state would give identical particles identical values.
    particle.seed       = static_cast<float>(Random::get(0.0, 1.0));
    particle.init.frame = particle.seed;
    for (auto& el : inis) el(particle, duration);
    // Nothing has moved it yet: an operator that compares the particle with
    // where it was last step finds it where it was placed.
    particle.prev_position = particle.position;
    return particle;
}

inline void ApplySign(Eigen::Vector3d& p, int32_t x, int32_t y, int32_t z) noexcept {
    if (x != 0) {
        p.x() = std::abs(p.x()) * (float)x;
    }
    if (y != 0) {
        p.y() = std::abs(p.y()) * (float)y;
    }
    if (z != 0) {
        p.z() = std::abs(p.z()) * (float)z;
    }
}

/// Where a spawn offset is measured from and how the control point turns it.
struct EmitterFrame {
    Eigen::Vector3d origin { Eigen::Vector3d::Zero() };
    Eigen::Matrix3d rotation { Eigen::Matrix3d::Identity() };
    bool            rotated { false };
    /// The layer's rotation and scale, for a world-space system: the spawn
    /// offset is turned and scaled by it, the origin added after, as it is.
    Eigen::Matrix3d world_linear { Eigen::Matrix3d::Identity() };
    bool            world { false };
};

inline EmitterFrame ResolveEmitterFrame(std::span<const ParticleControlpoint> cps, i32 cp_index,
                                        const std::array<float, 3>& authored) {
    EmitterFrame frame;
    frame.origin = Eigen::Vector3d {
        static_cast<double>(authored[0]),
        static_cast<double>(authored[1]),
        static_cast<double>(authored[2]),
    };
    if (cp_index >= 0 && static_cast<std::size_t>(cp_index) < cps.size()) {
        const auto& cp = cps[static_cast<std::size_t>(cp_index)];
        frame.origin += cp.offset;
        // Wallpaper Engine turns the spawn offset and its velocity direction by
        // the control point's orientation only for an emitter that names a
        // control point other than the first.
        if (cp_index != 0 && cp.has_rotation) {
            frame.rotation = cp.rotation;
            frame.rotated  = true;
        }
        if (cp.has_world_linear) {
            frame.world_linear = cp.world_linear;
            frame.world        = true;
        }
    }
    return frame;
}

/// The velocity initializers of the particles this emitter spawns read the
/// matrix of its control point, as Wallpaper Engine hands it to them: the layer's
/// for a worldspace system, unless the control point is pinned to the world.
inline void HandOnWorldLinear(const std::shared_ptr<ParticleSpawnContext>& spawn,
                              const EmitterFrame&                          frame) {
    if (spawn == nullptr) return;
    spawn->has_world_linear = frame.world;
    spawn->world_linear     = frame.world_linear;
}

inline float ResolveMultiplier(const std::shared_ptr<const float>& multiplier) {
    if (multiplier == nullptr) return 1.0f;
    return std::max(0.0f, *multiplier);
}

inline double UnitRandom() { return Random::get(0.0, 1.0); }

/// Direction a particle leaves its spawn point in: away from the emitter
/// centre, or, when it spawned on the centre, along a random direction drawn
/// over `directions` (Wallpaper Engine's fallback for a degenerate offset).
inline Eigen::Vector3d SpawnDirection(const Eigen::Vector3d& offset,
                                      const std::array<float, 3>& directions,
                                      const EmitterFrame& frame) {
    if (offset.squaredNorm() >= 1.0e-4) return offset.normalized();
    Eigen::Vector3d random {
        static_cast<double>(directions[0]) * (2.0 * UnitRandom() - 1.0),
        static_cast<double>(directions[1]) * (2.0 * UnitRandom() - 1.0),
        static_cast<double>(directions[2]) * (2.0 * UnitRandom() - 1.0),
    };
    if (frame.rotated) random = frame.rotation * random;
    if (frame.world) random = frame.world_linear * random;
    const double length = random.norm();
    return length > 1.0e-12 ? Eigen::Vector3d(random / length) : Eigen::Vector3d(Eigen::Vector3d::Zero());
}

/// The emitter's schedule: when it waits, emits, pauses and stops, and how
/// many particles one step owes. One per emitter per particle-system instance,
/// because a recycled instance starts its schedule again.
class EmitterClock {
public:
    EmitterClock(const ParticleEmitterTiming& timing, u32 instantaneous, bool one_per_frame,
                 float authored_rate)
        : m_timing(timing),
          m_instantaneous(instantaneous),
          m_one_per_frame(one_per_frame),
          m_authored_rate(authored_rate),
          m_delay(std::max(0.0f, timing.delay)),
          m_duration(std::max(0.0f, timing.duration)),
          m_pending(instantaneous) {
        // The shorter bound is the minimum, whichever way the file wrote them.
        if (m_timing.minPeriodicDuration > m_timing.maxPeriodicDuration) {
            std::swap(m_timing.minPeriodicDuration, m_timing.maxPeriodicDuration);
        }
        if (m_timing.minPeriodicDelay > m_timing.maxPeriodicDelay) {
            std::swap(m_timing.minPeriodicDelay, m_timing.maxPeriodicDelay);
        }
    }

    /// Particles this step asks for, before the system's capacity is applied.
    /// `rate` is particles per second already scaled by the count override and
    /// the audio level; `count_multiplier` scales a burst.
    u32 Step(double dt, double rate, float count_multiplier) {
        if (m_finished) return 0;
        if (m_delay > 0.0) {
            m_delay -= dt;
            return 0;
        }

        if (m_timing.periodic) {
            if (m_window > 0.0) {
                m_window -= dt;
                if (m_window < 0.0) {
                    m_window = -Lerp(m_timing.minPeriodicDelay, m_timing.maxPeriodicDelay);
                }
            } else {
                m_window += dt;
                if (m_window < 0.0) {
                    rate = 0.0;
                } else {
                    // A new window re-arms the burst and the per-window cap.
                    m_pending      = m_instantaneous;
                    m_emitted      = 0;
                    m_window       = Lerp(m_timing.minPeriodicDuration, m_timing.maxPeriodicDuration);
                    m_window_began = true;
                }
            }
        }

        // The burst is paid out once the count multiplier lets any of it through:
        // while a user-bound `count` holds it at zero the burst stays owed
        // (and the emitter is not finished) instead of being spent on nothing.
        u32 burst = 0;
        if (m_pending != 0 && count_multiplier > 0.0f) {
            burst = static_cast<u32>(
                std::ceil(static_cast<double>(m_pending) * static_cast<double>(count_multiplier)));
            m_pending = 0;
        }

        const double total = rate * dt + m_accum;
        u32          count = 0;
        // A hair of tolerance, as the accumulator is a sum of fractions: a rate
        // of sixty at sixty frames a second owes one particle every frame, not
        // one frame in a hundred late.
        constexpr double kTolerance = 1.0e-9;
        if (total + kTolerance < 1.0 || m_duration < 0.0) {
            // The burst is paid for out of the same account the rate draws on,
            // so a large burst holds the steady stream back for a while.
            m_accum = total - static_cast<double>(burst);
        } else {
            const double due = std::floor(total + kTolerance);
            m_accum          = total - (due + static_cast<double>(burst));
            double n         = due;
            if (m_one_per_frame) n = std::min(n, 1.0);
            if (m_timing.periodic && m_timing.maxToEmitPerPeriod != 0) {
                const double room = std::max(
                    0.0, static_cast<double>(m_timing.maxToEmitPerPeriod) - static_cast<double>(m_emitted));
                n = std::min(n, room);
                m_emitted += static_cast<u32>(n);
            }
            count = static_cast<u32>(std::min(n, 4.0e9));
        }
        EndOfStep(dt, m_pending != 0);
        return burst + count;
    }

    /// The audio-gated emitter: the level has already shaped the rate, silence
    /// discards the part of a particle owed, and a burst waits for sound.
    u32 StepAudio(double dt, double rate_per_second, float response, float count_multiplier) {
        if (m_finished) return 0;
        if (m_delay > 0.0) {
            m_delay -= dt;
            return 0;
        }
        bool paused = false;
        if (m_timing.periodic) {
            if (m_window > 0.0) {
                m_window -= dt;
                if (m_window < 0.0) {
                    m_window = -Lerp(m_timing.minPeriodicDelay, m_timing.maxPeriodicDelay);
                }
            } else {
                m_window += dt;
                if (m_window < 0.0) {
                    paused = true;
                } else {
                    m_window       = Lerp(m_timing.minPeriodicDuration, m_timing.maxPeriodicDuration);
                    m_window_began = true;
                    m_audio_burst_done = false;
                }
            }
        }
        u32 count = 0;
        if (paused) {
            // Nothing is emitted and nothing accrues while the window is shut.
        } else if (! std::isfinite(response) || response <= 0.0f || count_multiplier <= 0.0f) {
            m_accum = 0.0;
        } else {
            const float multiplier = std::min(response, 1.0f) * count_multiplier;
            // Accumulate fractional particles, not elapsed silent time or time at an old rate.
            m_accum += std::max(0.0, dt) * std::max(0.0, rate_per_second) * multiplier;
            count = GetEmitNum(m_accum, 1.0);
            if (m_instantaneous > 0 && ! m_audio_burst_done) {
                count = static_cast<u32>(
                    std::ceil(static_cast<float>(m_instantaneous) * multiplier));
                m_audio_burst_done = true;
            }
            if (m_one_per_frame) count = std::min(count, 1u);
        }
        // A burst that waits for sound is still to come.
        EndOfStep(dt, m_instantaneous > 0 && ! m_audio_burst_done);
        return count;
    }

    bool Finished() const noexcept { return m_finished; }

private:
    static double Lerp(double a, double b) { return a + UnitRandom() * (b - a); }

    void EndOfStep(double dt, bool burst_pending) {
        if (m_duration > 0.0) {
            m_duration -= dt;
            if (m_duration <= 0.0) {
                m_duration = -1.0;
                m_finished = true;
            }
        } else if (m_authored_rate <= 0.0f && ! burst_pending &&
                   ! (m_instantaneous != 0 && m_timing.periodic)) {
            // Nothing but an unrepeated burst is left to do.
            m_finished = true;
        }
    }

    ParticleEmitterTiming m_timing;
    u32                   m_instantaneous;
    bool                  m_one_per_frame;
    float                 m_authored_rate;
    double                m_delay;
    double                m_duration;
    double                m_accum { 0.0 };
    double                m_window { 0.0 };
    u32                   m_emitted { 0 };
    u32                   m_pending;
    bool                  m_finished { false };
    bool                  m_window_began { false };
    bool                  m_audio_burst_done { false };
};

/// One step's particle count for either emitter type.
template<typename Args>
u32 EmitterCount(const Args& args, EmitterClock& clock, double timepass) {
    const float count_multiplier = ResolveMultiplier(args.countMultiplier);
    if (! args.audioResponse) {
        return clock.Step(timepass, static_cast<double>(args.emitSpeed) * count_multiplier,
                          count_multiplier);
    }
    return clock.StepAudio(timepass, args.emitSpeed, args.audioResponse(), count_multiplier);
}
} // namespace

ParticleEmittOp ParticleBoxEmitterArgs::MakeEmittOp(ParticleBoxEmitterArgs a) {
    EmitterClock clock(a.timing, a.instantaneous, a.one_per_frame, a.emitSpeed);
    return [a, clock](std::vector<Particle>&       ps,
                      std::vector<ParticleInitOp>& inis,
                      u32                          maxcount,
                      double                       timepass,
                      std::span<const ParticleControlpoint>
                          controlpoints) mutable {
        const EmitterFrame frame = ResolveEmitterFrame(controlpoints, a.controlpoint, a.orgin);
        HandOnWorldLinear(a.spawn, frame);
        auto               GenBox = [&]() {
            // Per axis a signed draw scaled by `directions`; the minimum bounds
            // the distance from the centre, so a hollow box leaves its centre
            // empty and a negative minimum folds the two halves together.
            Eigen::Vector3d pos;
            for (int32_t i = 0; i < 3; i++) {
                const double s   = (2.0 * UnitRandom() - 1.0) * static_cast<double>(a.directions[i]);
                const double sgn = s > 0.0 ? 1.0 : (s < 0.0 ? -1.0 : 0.0);
                const double lo  = a.minDistance[i];
                const double hi  = a.maxDistance[i];
                pos[i]           = sgn * (lo + (hi - lo) * std::abs(s));
            }
            auto p = Particle();
            if (frame.rotated) pos = frame.rotation * pos;
            // A world-space system's layer turns and scales the offset, and the
            // particle leaves along the offset's new direction at its authored
            // speed.
            if (frame.world) pos = frame.world_linear * pos;
            ParticleModify::MoveTo(p, pos);
            ParticleModify::ChangeVelocity(
                p,
                Random::get(a.minSpeed, a.maxSpeed) * SpawnDirection(pos, a.directions, frame));

            ParticleModify::Move(p, frame.origin);
            return p;
        };
        const u32 emit_num = EmitterCount(a, clock, timepass);
        Emitt(ps, emit_num, maxcount, a.sort, [&]() {
            return Spwan(GenBox, inis, a.emitSpeed > 0.0f ? 1.0f / a.emitSpeed : 0.0f);
        });
    };
}

ParticleEmittOp ParticleSphereEmitterArgs::MakeEmittOp(ParticleSphereEmitterArgs a) {
    using namespace Eigen;
    EmitterClock clock(a.timing, a.instantaneous, a.one_per_frame, a.emitSpeed);
    return [a, clock](std::vector<Particle>&       ps,
                      std::vector<ParticleInitOp>& inis,
                      u32                          maxcount,
                      double                       timepass,
                      std::span<const ParticleControlpoint>
                          controlpoints) mutable {
        const EmitterFrame frame = ResolveEmitterFrame(controlpoints, a.controlpoint, a.orgin);
        HandOnWorldLinear(a.spawn, frame);
        const double       cone_floor = -std::cos(EIGEN_PI * static_cast<double>(a.cone));
        auto               GenSphere = [&]() {
            auto p = Particle();
            // A point of the unit ball, uniform by volume, stretched by
            // `directions`. Its length, not a separate radius draw, places the
            // particle between the minimum and maximum distance, so a flat
            // `directions` (a disc) fills toward the middle the way the ball's
            // projection does. The polar axis is x; `cone` narrows the ball to
            // a cone about +x.
            const double z      = UnitRandom() * (1.0 - cone_floor) + cone_floor;
            const double s      = std::sqrt(std::max(0.0, 1.0 - z * z));
            const double phi    = 2.0 * EIGEN_PI * UnitRandom();
            const double radius = std::cbrt(UnitRandom());
            Vector3d     v {
                radius * z * static_cast<double>(a.directions[0]),
                radius * s * std::sin(phi) * static_cast<double>(a.directions[1]),
                radius * s * std::cos(phi) * static_cast<double>(a.directions[2]),
            };
            const double length = v.norm();
            Vector3d     offset = Vector3d::Zero();
            if (length > 1.0e-12) {
                Vector3d direction = v / length;
                ApplySign(direction, a.sign[0], a.sign[1], a.sign[2]);
                offset = (static_cast<double>(a.minDistance) +
                          (static_cast<double>(a.maxDistance) - static_cast<double>(a.minDistance)) *
                              length) *
                         direction;
            }
            if (frame.rotated) offset = frame.rotation * offset;
            if (frame.world) offset = frame.world_linear * offset;

            ParticleModify::MoveTo(p, offset);
            ParticleModify::ChangeVelocity(
                p,
                Random::get(a.minSpeed, a.maxSpeed) * SpawnDirection(offset, a.directions, frame));

            ParticleModify::Move(p, frame.origin);
            return p;
        };
        const u32 emit_num = EmitterCount(a, clock, timepass);
        Emitt(ps, emit_num, maxcount, a.sort, [&]() {
            return Spwan(GenSphere, inis, a.emitSpeed > 0.0f ? 1.0f / a.emitSpeed : 0.0f);
        });
    };
}
