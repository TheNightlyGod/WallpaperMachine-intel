// Clean-room implementation from the WallpaperMachine spec e4-particle-simulation.md; written without access to the original source.
#include "ParticleEmitter.h"
#include "ParticleModify.h"
#include "Utils/Algorism.h"
#include "Utils/Logging.h"
#include "Utils/Random.hpp"

#include "Utils/Linalg.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <random>
#include <utility>

using namespace wallpaper;

namespace
{

using Vec3 = linalg::Vector3d;
namespace PM = ParticleModify;

/// A draw from [0, 1).
double Uniform() { return Random::get(0.0, 1.0); }

double Lerp(double a, double b, double t) { return a + (b - a) * t; }

Vec3 ToVec(const std::array<float, 3>& v) {
    return { static_cast<double>(v[0]), static_cast<double>(v[1]), static_cast<double>(v[2]) };
}

/// The most rate-driven particles one step may attempt: the balance is capped
/// here so a huge step cannot ask for an unbounded burst.
constexpr double kMaxDuePerStep = 4.0e9;

/// What every emitter shares, whichever shape it places particles in.
struct EmitterConfig {
    double                                rate { 0.0 };
    u32                                   burst { 0 };
    bool                                  one_per_frame { false };
    bool                                  sort { false };
    i32                                   controlpoint { 0 };
    Vec3                                  directions { 1, 1, 0 };
    Vec3                                  origin { 0, 0, 0 };
    double                                min_speed { 0.0 };
    double                                max_speed { 0.0 };
    std::shared_ptr<const float>          count;
    std::function<float()>                audio;
    ParticleEmitterTiming                 timing;
    std::shared_ptr<ParticleSpawnContext> spawn;
};

/// Where an emitter is in its timetable and how much it owes. One lives in each
/// emit callable, so every copy of the callable (one per instance) keeps its own.
struct Schedule {
    double delay_left { 0.0 };
    double duration_left { 0.0 };
    bool   finished { false };
    bool   burst_pending { false };
    double balance { 0.0 };
    double last_count { 1.0 };

    // Periodic windows.
    enum class Phase { Fresh, InWindow, InPause };
    Phase  phase { Phase::Fresh };
    double window_left { 0.0 };
    double pause_left { 0.0 };
    u32    window_emitted { 0 };
};

double LengthBetween(float a, float b) {
    return Random::get(static_cast<double>(a), static_cast<double>(b));
}

/// The multiplier of the instance override, read now: absent counts 1, a
/// negative value 0, and a value that is not a number keeps the last good one.
double CountMultiplier(const EmitterConfig& cfg, Schedule& s) {
    if (! cfg.count) return 1.0;
    const double v = static_cast<double>(*cfg.count);
    if (std::isfinite(v)) s.last_count = std::max(v, 0.0);
    return s.last_count;
}

void OpenWindow(const EmitterConfig& cfg, Schedule& s) {
    s.phase          = Schedule::Phase::InWindow;
    s.window_left    = LengthBetween(cfg.timing.minPeriodicDuration, cfg.timing.maxPeriodicDuration);
    s.window_emitted = 0;
    s.burst_pending  = cfg.burst > 0;
}

/// Moves a periodic emitter's windows on by `dt`; true when this step is inside
/// a window. The window runs out only by going below zero, and the step that
/// does is its last; reaching zero exactly opens the next window at once.
bool StepWindows(const EmitterConfig& cfg, Schedule& s, double dt) {
    using Phase = Schedule::Phase;
    if (s.phase == Phase::Fresh) {
        OpenWindow(cfg, s);
        return true;
    }
    if (s.phase == Phase::InWindow) {
        if (s.window_left > 0.0) {
            s.window_left -= dt;
            return true;
        }
        if (s.window_left == 0.0) {
            OpenWindow(cfg, s);
            return true;
        }
        s.phase      = Phase::InPause;
        s.pause_left = LengthBetween(cfg.timing.minPeriodicDelay, cfg.timing.maxPeriodicDelay);
    }
    s.pause_left -= dt;
    if (s.pause_left > 0.0) return false;
    OpenWindow(cfg, s);
    return true;
}

/// The whole number of particles `balance` holds, with a sliver of slack so
/// rate 48 at 1/48 s is one a step despite rounding.
double WholeDue(double balance) {
    const double whole = std::floor(balance + 1.0e-9);
    return std::clamp(whole, 0.0, kMaxDuePerStep);
}

double BurstSize(double burst, double factor) {
    return std::ceil(burst * factor - 1.0e-7);
}

/// How many particles this step attempts. Advances the schedule.
double PlanStep(const EmitterConfig& cfg, Schedule& s, double dt) {
    if (s.finished) return 0.0;

    const bool   audio_gated = static_cast<bool>(cfg.audio);
    double       level       = 1.0;
    if (audio_gated) {
        const double raw = static_cast<double>(cfg.audio());
        level            = (std::isfinite(raw) && raw > 0.0) ? raw : 0.0;
    }
    const double factor = CountMultiplier(cfg, s);

    if (s.delay_left > 0.0) {
        s.delay_left -= dt;
        return 0.0;
    }
    bool last_step = false;
    if (cfg.timing.duration > 0.0f) {
        s.duration_left -= dt;
        last_step = s.duration_left <= 0.0;
    }
    const bool in_window = cfg.timing.periodic ? StepWindows(cfg, s, dt) : true;

    double emit = 0.0;
    if (in_window) {
        if (audio_gated) {
            if (level > 0.0 && factor > 0.0) {
                const double l = std::min(level, 1.0);
                if (s.burst_pending) {
                    // The burst waits for sound and replaces this step's stream.
                    s.burst_pending = false;
                    emit            = BurstSize(cfg.burst, l * factor);
                } else {
                    s.balance += cfg.rate * l * factor * dt;
                    const double due = WholeDue(s.balance);
                    s.balance -= due;
                    emit = due;
                }
                if (cfg.one_per_frame) emit = std::min(emit, 1.0);
            } else {
                // Silence: nothing builds up, and a long quiet step is never repaid.
                s.balance = std::min(s.balance, 0.0);
            }
        } else {
            s.balance += cfg.rate * factor * dt;
            if (! std::isfinite(s.balance)) s.balance = 0.0;
            const double due   = WholeDue(s.balance);
            double       paid  = due;
            if (cfg.one_per_frame) paid = std::min(paid, 1.0);
            if (cfg.timing.periodic && cfg.timing.maxToEmitPerPeriod > 0) {
                const double room =
                    static_cast<double>(cfg.timing.maxToEmitPerPeriod) -
                    static_cast<double>(std::min(s.window_emitted, cfg.timing.maxToEmitPerPeriod));
                paid = std::min(paid, room);
            }
            double burst = 0.0;
            if (s.burst_pending && factor > 0.0) {
                burst           = BurstSize(cfg.burst, factor);
                s.burst_pending = false;
            }
            // Everything that fell due is paid for, whether or not it got out.
            s.balance -= due + burst;
            s.window_emitted += static_cast<u32>(std::min(paid, kMaxDuePerStep));
            emit = paid + burst;
        }
    }

    if (last_step) s.finished = true;
    if (cfg.rate == 0.0 && cfg.timing.duration <= 0.0f && ! s.burst_pending &&
        ! (cfg.timing.periodic && cfg.burst > 0)) {
        s.finished = true;
    }
    return emit;
}

/// Puts the slots of a plain rope in order: particles that were already alive,
/// then this step's newborns, then dead slots. Linear, with scratch space that
/// is kept between calls.
void OrderSlots(std::vector<Particle>& slots) {
    const auto rank = [](const Particle& p) {
        if (! PM::LifetimeOk(p)) return 2;
        return PM::IsNew(p) ? 1 : 0;
    };
    int  highest = 0;
    bool ordered = true;
    for (const auto& p : slots) {
        const int r = rank(p);
        if (r < highest) {
            ordered = false;
            break;
        }
        highest = r;
    }
    if (ordered) return;
    thread_local std::vector<Particle> scratch;
    scratch.clear();
    for (int wanted = 0; wanted < 3; ++wanted) {
        for (const auto& p : slots) {
            if (rank(p) == wanted) scratch.push_back(p);
        }
    }
    // Copied back, not swapped: a swap would hand this instance's buffer to the
    // next caller and take theirs, so instances of different sizes would make
    // the scratch grow again every frame.
    std::copy(scratch.begin(), scratch.end(), slots.begin());
}

/// The control point an emitter is framed by, or null when it has none.
const ParticleControlpoint* FramePoint(i32 index, std::span<const ParticleControlpoint> points) {
    if (index < 0) index = 7;
    if (static_cast<std::size_t>(index) >= points.size()) return nullptr;
    return &points[static_cast<std::size_t>(index)];
}

/// An offset turned by the orientation of the emitter's control point (never
/// the first point's) and carried through the layer matrix that point holds.
Vec3 Frame(const Vec3& offset, const ParticleControlpoint* point, i32 index) {
    Vec3 out = offset;
    if (point == nullptr) return out;
    if (index != 0 && point->has_rotation) out = point->rotation * out;
    if (point->has_world_linear) out = point->world_linear * out;
    return out;
}

Particle MakeParticle(const EmitterConfig& cfg, const Vec3& raw_offset,
                      const ParticleControlpoint* point, i32 index) {
    Particle     p;
    const Vec3   offset = Frame(raw_offset, point, index);
    Vec3         heading;
    if (offset.norm() < 0.01) {
        const Vec3 random { Random::get(-cfg.directions.x(), cfg.directions.x()),
                            Random::get(-cfg.directions.y(), cfg.directions.y()),
                            Random::get(-cfg.directions.z(), cfg.directions.z()) };
        heading = Frame(random, point, index);
        const double len = heading.norm();
        heading          = len > 0.0 ? Vec3(heading / len) : Vec3::Zero();
    } else {
        heading = offset / offset.norm();
    }
    const double speed = Random::get(cfg.min_speed, cfg.max_speed);

    Vec3 position = cfg.origin + offset;
    if (point != nullptr) position += point->offset;
    PM::MoveTo(p, position);
    PM::InitVelocity(p, heading * speed);
    return p;
}

/// Records what an initializer chain left as the particle's birth state.
void SealBirth(Particle& p, double seed) {
    p.seed = static_cast<float>(std::min(seed, static_cast<double>(std::nextafter(1.0f, 0.0f))));
    p.init.frame = p.seed;
}

void FinishBirth(Particle& p) {
    p.prev_position = p.position;
    p.init.color    = p.color;
    p.init.alpha    = p.alpha;
    p.init.size     = p.size;
    p.mark_new      = true;
}

/// One emitter step on one instance. `place` returns an unturned offset.
template<class Place>
void EmitInto(const EmitterConfig& cfg, Schedule& schedule, Place& place,
              std::vector<Particle>& slots, std::vector<ParticleInitOp>& initializers,
              u32 maxcount, double dt_in, std::span<const ParticleControlpoint> controlpoints) {
    const double dt = (std::isfinite(dt_in) && dt_in > 0.0) ? dt_in : 0.0;

    const i32                   index = cfg.controlpoint < 0 ? 7 : cfg.controlpoint;
    const ParticleControlpoint* point = FramePoint(index, controlpoints);
    if (cfg.spawn) {
        cfg.spawn->has_world_linear = point != nullptr && point->has_world_linear;
        cfg.spawn->world_linear =
            cfg.spawn->has_world_linear ? point->world_linear : linalg::Matrix3d::Identity();
    }

    const double wanted = PlanStep(cfg, schedule, dt);
    if (wanted >= 1.0) {
        const double duration = cfg.rate > 0.0 ? 1.0 / cfg.rate : 0.0;
        std::size_t  cursor   = 0;
        for (double made = 0.0; made < wanted; made += 1.0) {
            while (cursor < slots.size() && PM::LifetimeOk(slots[cursor])) ++cursor;
            if (cursor == slots.size()) {
                if (slots.size() >= maxcount) break;
                slots.emplace_back();
            }
            Particle& slot = slots[cursor++];
            Particle  p    = MakeParticle(cfg, place(), point, index);
            SealBirth(p, Uniform());
            for (auto& init : initializers) init(p, duration);
            FinishBirth(p);
            slot = p;
        }
    }
    if (cfg.sort) OrderSlots(slots);
}

template<class Place>
ParticleEmittOp MakeOp(EmitterConfig cfg, Place place) {
    Schedule schedule;
    schedule.delay_left     = cfg.timing.delay;
    schedule.duration_left  = cfg.timing.duration;
    schedule.burst_pending  = cfg.burst > 0;
    return [cfg = std::move(cfg), schedule, place](std::vector<Particle>&           slots,
                                                    std::vector<ParticleInitOp>&     initializers,
                                                    u32 maxcount, double dt,
                                                    std::span<const ParticleControlpoint> points) mutable {
        EmitInto(cfg, schedule, place, slots, initializers, maxcount, dt, points);
    };
}

} // namespace

ParticleEmittOp ParticleBoxEmitterArgs::MakeEmittOp(ParticleBoxEmitterArgs a) {
    EmitterConfig cfg;
    cfg.rate          = a.emitSpeed;
    cfg.burst         = a.instantaneous;
    cfg.one_per_frame = a.one_per_frame;
    cfg.sort          = a.sort;
    cfg.controlpoint  = a.controlpoint;
    cfg.directions    = ToVec(a.directions);
    cfg.origin        = ToVec(a.orgin);
    cfg.min_speed     = a.minSpeed;
    cfg.max_speed     = a.maxSpeed;
    cfg.count         = std::move(a.countMultiplier);
    cfg.audio         = std::move(a.audioResponse);
    cfg.timing        = a.timing;
    cfg.spawn         = std::move(a.spawn);

    const Vec3 dir = cfg.directions;
    const Vec3 lo  = ToVec(a.minDistance);
    const Vec3 hi  = ToVec(a.maxDistance);
    return MakeOp(std::move(cfg), [dir, lo, hi]() {
        Vec3 offset;
        for (int i = 0; i < 3; ++i) {
            const double s    = (2.0 * Uniform() - 1.0) * dir[i];
            const double sign = (s > 0.0) - (s < 0.0);
            offset[i]         = sign * Lerp(lo[i], hi[i], std::abs(s));
        }
        return offset;
    });
}

ParticleEmittOp ParticleSphereEmitterArgs::MakeEmittOp(ParticleSphereEmitterArgs a) {
    EmitterConfig cfg;
    cfg.rate          = a.emitSpeed;
    cfg.burst         = a.instantaneous;
    cfg.one_per_frame = a.one_per_frame;
    cfg.sort          = a.sort;
    cfg.controlpoint  = a.controlpoint;
    cfg.directions    = ToVec(a.directions);
    cfg.origin        = ToVec(a.orgin);
    cfg.min_speed     = a.minSpeed;
    cfg.max_speed     = a.maxSpeed;
    cfg.count         = std::move(a.countMultiplier);
    cfg.audio         = std::move(a.audioResponse);
    cfg.timing        = a.timing;
    cfg.spawn         = std::move(a.spawn);

    const Vec3   dir      = cfg.directions;
    const double lo       = a.minDistance;
    const double hi       = a.maxDistance;
    const double floor_z  = -std::cos(linalg::Pi * static_cast<double>(a.cone));
    const std::array<int32_t, 3> sign = a.sign;
    return MakeOp(std::move(cfg), [dir, lo, hi, floor_z, sign]() {
        // A point of the unit ball by volume, polar axis along +x, stretched
        // by `directions`; its stretched length sets the distance.
        const double z      = Lerp(floor_z, 1.0, Uniform());
        const double phi    = 2.0 * linalg::Pi * Uniform();
        const double radius = std::cbrt(Uniform());
        const double ring   = std::sqrt(std::max(0.0, 1.0 - z * z));
        const Vec3   point { radius * z * dir.x(), radius * ring * std::sin(phi) * dir.y(),
                             radius * ring * std::cos(phi) * dir.z() };
        const double length = point.norm();
        if (! (length > 0.0)) return Vec3 { 0.0, 0.0, 0.0 };
        Vec3 unit = point / length;
        for (int i = 0; i < 3; ++i) {
            if (sign[static_cast<std::size_t>(i)] != 0)
                unit[i] = std::abs(unit[i]) * static_cast<double>(sign[static_cast<std::size_t>(i)]);
        }
        return Vec3(unit * Lerp(lo, hi, length));
    });
}
