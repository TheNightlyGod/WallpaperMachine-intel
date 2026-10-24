// Clean-room implementation from the WallpaperMachine spec e4-particle-simulation.md; written without access to the original source.
#pragma once

#include "Particle.h"

#include "Utils/Linalg.hpp"
#include <cmath>
#include <cstdint>

namespace wallpaper
{

namespace ParticleModify
{

namespace detail
{
// A Vector3d view of a stored Vector3f.
inline linalg::Vector3d Wide(const linalg::Vector3f& v) noexcept {
    return { static_cast<double>(v.x()), static_cast<double>(v.y()), static_cast<double>(v.z()) };
}
inline linalg::Vector3f Narrow(const linalg::Vector3d& v) noexcept {
    return { static_cast<float>(v.x()), static_cast<float>(v.y()), static_cast<float>(v.z()) };
}
// `v` turned by `angle` radians about the unit vector `axis` (right-handed).
inline linalg::Vector3d TurnAbout(const linalg::Vector3d& v, const linalg::Vector3d& axis,
                                  double angle) noexcept {
    const double c = std::cos(angle), s = std::sin(angle);
    return v * c + axis.cross(v) * s + axis * (axis.dot(v) * (1.0 - c));
}
} // namespace detail

// --- position ---------------------------------------------------------------------
inline void Move(Particle& p, const linalg::Vector3d& acc) noexcept {
    p.position = detail::Narrow(detail::Wide(p.position) + acc);
}
inline void Move(Particle& p, double x, double y, double z) noexcept {
    Move(p, linalg::Vector3d { x, y, z });
}
inline void MoveTo(Particle& p, const linalg::Vector3d& pos) noexcept {
    p.position = detail::Narrow(pos);
}
inline void MoveTo(Particle& p, double x, double y, double z) noexcept {
    MoveTo(p, linalg::Vector3d { x, y, z });
}
inline void MoveToNegZ(Particle& p) noexcept { p.position.z() = -std::abs(p.position.z()); }
inline void MoveByTime(Particle& p, double t) noexcept {
    Move(p, detail::Wide(p.velocity) * t);
}
inline void MoveMultiply(Particle& p, const linalg::Vector3d& para) noexcept {
    MoveTo(p, detail::Wide(p.position).cwiseProduct(para));
}
inline void MoveMultiply(Particle& p, double x, double y, double z) noexcept {
    MoveMultiply(p, linalg::Vector3d { x, y, z });
}
inline void MoveApplySign(Particle& p, int32_t x, int32_t y, int32_t z) noexcept {
    const int32_t sign[3] = { x, y, z };
    for (int i = 0; i < 3; i++) {
        if (sign[i] != 0) p.position[i] = std::abs(p.position[i]) * static_cast<float>(sign[i]);
    }
}
inline void SphereDirectOffset(Particle& p, const linalg::Vector3d& base, double direct) noexcept {
    const linalg::Vector3d pos  = detail::Wide(p.position);
    linalg::Vector3d       axis = base.cross(pos);
    const double           len  = axis.norm();
    if (! (len > 0.0)) return;
    MoveTo(p, detail::TurnAbout(pos, axis / len, direct));
}
inline void RotatePos(Particle& p, double x, double y, double z) noexcept {
    linalg::Vector3d v = detail::Wide(p.position);
    v                  = detail::TurnAbout(v, linalg::Vector3d { 0.0, 1.0, 0.0 }, y);
    v                  = detail::TurnAbout(v, linalg::Vector3d { 1.0, 0.0, 0.0 }, x);
    v                  = detail::TurnAbout(v, linalg::Vector3d { 0.0, 0.0, 1.0 }, -z);
    MoveTo(p, v);
}

// --- lifetime ---------------------------------------------------------------------
inline void ChangeLifetime(Particle& p, double l) noexcept {
    p.lifetime = static_cast<float>(static_cast<double>(p.lifetime) + l);
}
inline double LifetimePos(const Particle& p) {
    // Expired, or no usable initial lifetime: the end of life.
    if (p.lifetime < 0.0f || ! (p.init.lifetime > 0.0f)) return 1.0;
    const double t = 1.0 - static_cast<double>(p.lifetime) / static_cast<double>(p.init.lifetime);
    return std::isfinite(t) ? t : 1.0;
}
inline double LifetimePassed(const Particle& p) noexcept {
    return static_cast<double>(p.init.lifetime) - static_cast<double>(p.lifetime);
}
inline bool LifetimeOk(const Particle& p) noexcept { return p.lifetime > 0.0f; }

// --- additive ---------------------------------------------------------------------
inline void ChangeColor(Particle& p, const linalg::Vector3d& c) noexcept {
    p.color = detail::Narrow(detail::Wide(p.color) + c);
}
inline void ChangeColor(Particle& p, double r, double g, double b) {
    ChangeColor(p, linalg::Vector3d { r, g, b });
}
inline void ChangeRotation(Particle& p, const linalg::Vector3d& r) noexcept {
    p.rotation = detail::Narrow(detail::Wide(p.rotation) + r);
}
inline void ChangeRotation(Particle& p, double x, double y, double z) {
    ChangeRotation(p, linalg::Vector3d { x, y, z });
}
inline void ChangeVelocity(Particle& p, const linalg::Vector3d& v) noexcept {
    p.velocity = detail::Narrow(detail::Wide(p.velocity) + v);
}
inline void ChangeVelocity(Particle& p, double x, double y, double z) noexcept {
    ChangeVelocity(p, linalg::Vector3d { x, y, z });
}
inline void Accelerate(Particle& p, const linalg::Vector3d& acc, double t) noexcept {
    ChangeVelocity(p, acc * t);
}
inline void ChangeAngularVelocity(Particle& p, const linalg::Vector3d& v) noexcept {
    p.angularVelocity = detail::Narrow(detail::Wide(p.angularVelocity) + v);
}
inline void ChangeAngularVelocity(Particle& p, double x, double y, double z) noexcept {
    ChangeAngularVelocity(p, linalg::Vector3d { x, y, z });
}
inline void AngularAccelerate(Particle& p, const linalg::Vector3d& acc, double t) noexcept {
    ChangeAngularVelocity(p, acc * t);
}
inline void Rotate(Particle& p, const linalg::Vector3d& r) noexcept { ChangeRotation(p, r); }
inline void Rotate(Particle& p, double x, double y, double z) noexcept {
    ChangeRotation(p, linalg::Vector3d { x, y, z });
}
inline void RotateByTime(Particle& p, double t) noexcept {
    ChangeRotation(p, detail::Wide(p.angularVelocity) * t);
}

// --- multiplicative and size ------------------------------------------------------
inline void MutiplyAlpha(Particle& p, double a) {
    p.alpha = static_cast<float>(static_cast<double>(p.alpha) * a);
}
inline void MutiplySize(Particle& p, double s) {
    p.size = static_cast<float>(static_cast<double>(p.size) * s);
}
inline void MutiplyColor(Particle& p, const linalg::Vector3d& c) {
    p.color = detail::Narrow(detail::Wide(p.color).cwiseProduct(c));
}
inline void MutiplyColor(Particle& p, double r, double g, double b) {
    MutiplyColor(p, linalg::Vector3d { r, g, b });
}
inline void MutiplyVelocity(Particle& p, double m) {
    p.velocity = detail::Narrow(detail::Wide(p.velocity) * m);
}
inline void ChangeSize(Particle& p, double s) {
    p.size = static_cast<float>(static_cast<double>(p.size) + s);
}
inline void ChangeAlpha(Particle& p, double a) {
    p.alpha = static_cast<float>(static_cast<double>(p.alpha) + a);
}

// --- birth ------------------------------------------------------------------------
inline void InitLifetime(Particle& p, float l) noexcept {
    p.lifetime      = l;
    p.init.lifetime = l;
}
inline void InitSize(Particle& p, double s) {
    p.size      = static_cast<float>(s);
    p.init.size = p.size;
}
inline void InitAlpha(Particle& p, double a) {
    p.alpha      = static_cast<float>(a);
    p.init.alpha = p.alpha;
}
inline void InitColor(Particle& p, double r, double g, double b) {
    p.color      = detail::Narrow(linalg::Vector3d { r, g, b });
    p.init.color = p.color;
}
inline void InitVelocity(Particle& p, const linalg::Vector3d& v) {
    p.velocity = detail::Narrow(v);
}
inline void InitVelocity(Particle& p, double x, double y, double z) {
    InitVelocity(p, linalg::Vector3d { x, y, z });
}
inline void MutiplyInitLifeTime(Particle& p, double m) {
    p.lifetime      = static_cast<float>(static_cast<double>(p.lifetime) * m);
    p.init.lifetime = p.lifetime;
}
inline void MutiplyInitAlpha(Particle& p, double m) {
    MutiplyAlpha(p, m);
    p.init.alpha = p.alpha;
}
inline void MutiplyInitSize(Particle& p, double m) {
    MutiplySize(p, m);
    p.init.size = p.size;
}
inline void MutiplyInitColor(Particle& p, double r, double g, double b) {
    MutiplyColor(p, r, g, b);
    p.init.color = p.color;
}

// --- per-step restore and the fresh flag ------------------------------------------
inline void Reset(Particle& p) {
    p.color = p.init.color;
    p.alpha = p.init.alpha;
    p.size  = p.init.size;
}
inline void MarkOld(Particle& p) { p.mark_new = false; }
inline bool IsNew(const Particle& p) { return p.mark_new; }

inline const linalg::Vector3f& GetPos(const Particle& p) { return p.position; }
inline const linalg::Vector3f& GetVelocity(const Particle& p) { return p.velocity; }
inline const linalg::Vector3f& GetAngular(const Particle& p) { return p.rotation; }

}; // namespace ParticleModify
} // namespace wallpaper
