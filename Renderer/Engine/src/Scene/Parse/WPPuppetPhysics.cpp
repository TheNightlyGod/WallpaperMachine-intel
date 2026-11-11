// Clean-room implementation from the WallpaperMachine spec p5-models-puppets.md; written without access to the original source.
// Puppet bone simulation: Wallpaper Engine 2.8.0.42 rules from we_ParseBoneSimulationJson
// 0x140265C30, the composer 0x1401FDF90 and the script impulse 0x140210990.
#include "WPPuppetPhysics.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <string>

#include <nlohmann/json.hpp>

#include "wpscene/WPObjectSchema.hpp"

namespace wallpaper
{
namespace
{
using V3 = std::array<double, 3>;
using M3 = std::array<double, 9>; // column-major, m[column * 3 + row]

constexpr double kPi       = 3.14159265358979323846;
constexpr double kDegToRad = 0.01745329238474369; // 0x140492628
constexpr double kRadToDeg = 57.295780181884766;  // 0x1404928D0
constexpr double kStepRate = 60.0;                // 1 / 0x140492624 (1/60 s)

V3     Add(const V3& a, const V3& b) { return { a[0] + b[0], a[1] + b[1], a[2] + b[2] }; }
V3     Sub(const V3& a, const V3& b) { return { a[0] - b[0], a[1] - b[1], a[2] - b[2] }; }
V3     Scale(const V3& a, double k) { return { a[0] * k, a[1] * k, a[2] * k }; }
double Dot(const V3& a, const V3& b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
V3     Cross(const V3& a, const V3& b) {
    return { a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
double Length(const V3& a) { return std::sqrt(Dot(a, a)); }
// A zero vector stays zero (Wallpaper Engine's would turn every lane into NaN).
V3 Normalized(const V3& a) {
    const double l = Length(a);
    return l > 0.0 && std::isfinite(l) ? Scale(a, 1.0 / l) : V3 { 0.0, 0.0, 0.0 };
}
V3 Apply(const M3& m, const V3& v) {
    return { m[0] * v[0] + m[3] * v[1] + m[6] * v[2], m[1] * v[0] + m[4] * v[1] + m[7] * v[2],
             m[2] * v[0] + m[5] * v[1] + m[8] * v[2] };
}
M3 Mul(const M3& a, const M3& b) {
    M3 out {};
    for (int c = 0; c < 3; c++)
        for (int r = 0; r < 3; r++)
            for (int k = 0; k < 3; k++) out[c * 3 + r] += a[k * 3 + r] * b[c * 3 + k];
    return out;
}
bool Inverse(const M3& m, M3& out) {
    const double a = m[0], b = m[3], c = m[6], d = m[1], e = m[4], f = m[7], g = m[2], h = m[5], i = m[8];
    const double c00 = e * i - f * h, c01 = f * g - d * i, c02 = d * h - e * g;
    const double det = a * c00 + b * c01 + c * c02;
    if (! std::isfinite(det) || det == 0.0) return false;
    const double inv = 1.0 / det;
    out = { c00 * inv,           c01 * inv,           c02 * inv,           (c * h - b * i) * inv, (a * i - c * g) * inv,
            (b * g - a * h) * inv, (b * f - c * e) * inv, (c * d - a * f) * inv, (a * e - b * d) * inv };
    return std::all_of(out.begin(), out.end(), [](double v) { return std::isfinite(v); });
}
M3 Linear(const PhysicsMatrix& m) {
    return { m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10] };
}
V3 Column(const M3& m, int c) { return { m[c * 3], m[c * 3 + 1], m[c * 3 + 2] }; }

struct Q {
    double w { 1.0 }, x { 0.0 }, y { 0.0 }, z { 0.0 };
};
Q Mul(const Q& a, const Q& b) {
    return { a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z, a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
             a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x, a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w };
}
Q Conj(const Q& a) { return { a.w, -a.x, -a.y, -a.z }; }
// sub_140217AC0: a zero quaternion becomes the identity.
Q Normalized(const Q& q) {
    const double l = std::sqrt(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z);
    if (! (l > 0.0) || ! std::isfinite(l)) return {};
    return { q.w / l, q.x / l, q.y / l, q.z / l };
}
// glm::slerp, sub_140216070: the shorter way round, a plain lerp above a cosine of 0.9999999.
Q Slerp(const Q& a, Q b, double t) {
    double d = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z;
    if (d < 0.0) {
        b = { -b.w, -b.x, -b.y, -b.z };
        d = -d;
    }
    if (d <= 0.9999999) {
        const double angle = std::acos(d);
        const double s     = std::sin(angle);
        const double ka = std::sin((1.0 - t) * angle) / s, kb = std::sin(t * angle) / s;
        return { a.w * ka + b.w * kb, a.x * ka + b.x * kb, a.y * ka + b.y * kb, a.z * ka + b.z * kb };
    }
    return { a.w * (1.0 - t) + b.w * t, a.x * (1.0 - t) + b.x * t, a.y * (1.0 - t) + b.y * t,
             a.z * (1.0 - t) + b.z * t };
}
// glm::rotation(from, to), sub_1402167C0: the turn that carries unit `from` onto unit `to`.
Q Rotation(const V3& from, const V3& to) {
    const double c = Dot(from, to);
    if (c >= 0.9999999) return {};
    if (c < -0.9999999) {
        V3 axis = Cross({ 0.0, 0.0, 1.0 }, from);
        if (Dot(axis, axis) < 1.1920929e-7) axis = Cross({ 1.0, 0.0, 0.0 }, from);
        axis = Normalized(axis);
        return { std::cos(kPi * 0.5), axis[0], axis[1], axis[2] };
    }
    const double s = std::sqrt((1.0 + c) * 2.0);
    const V3     a = Cross(from, to);
    return { s * 0.5, a[0] / s, a[1] / s, a[2] / s };
}
// The quaternion of Rz·Ry·Rx (angles in radians), as 0x140202b25 and 0x140210b04 compose it.
Q FromAngles(const V3& e) {
    const double cx = std::cos(e[0] * 0.5), sx = std::sin(e[0] * 0.5);
    const double cy = std::cos(e[1] * 0.5), sy = std::sin(e[1] * 0.5);
    const double cz = std::cos(e[2] * 0.5), sz = std::sin(e[2] * 0.5);
    return { cx * cy * cz + sx * sy * sz, sx * cy * cz - cx * sy * sz, cx * sy * cz + sx * cy * sz,
             cx * cy * sz - sx * sy * cz };
}
// glm::mat3_cast, sub_140216280.
M3 MatrixOf(const Q& q) {
    const double xx = q.x * q.x, yy = q.y * q.y, zz = q.z * q.z, xy = q.x * q.y, xz = q.x * q.z;
    const double yz = q.y * q.z, wx = q.w * q.x, wy = q.w * q.y, wz = q.w * q.z;
    return { 1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy), 2 * (xy - wz), 1 - 2 * (xx + zz),
             2 * (yz + wx),     2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy) };
}
// Rz·Ry·Rx (0x14020167b).
M3 MatrixOf(const V3& e) {
    const double cx = std::cos(e[0]), sx = std::sin(e[0]), cy = std::cos(e[1]), sy = std::sin(e[1]);
    const double cz = std::cos(e[2]), sz = std::sin(e[2]);
    return { cy * cz,
             cy * sz,
             -sy,
             sx * sy * cz - cx * sz,
             sx * sy * sz + cx * cz,
             sx * cy,
             cx * sy * cz + sx * sz,
             cx * sy * sz - sx * cz,
             cx * cy };
}
// glm::extractEulerAngleZYX (0x140201e10): back to (x, y, z).
V3 AnglesOf(const M3& m) {
    const double z  = std::atan2(m[1], m[0]);
    const double c2 = std::sqrt(m[5] * m[5] + m[8] * m[8]);
    const double y  = std::atan2(-m[2], c2);
    const double s1 = std::sin(z), c1 = std::cos(z);
    const double x  = std::atan2(s1 * m[6] - c1 * m[7], c1 * m[4] - s1 * m[3]);
    return { x, y, z };
}
// lt (0x140201a94): each axis of the angular velocity turns at most `limit` degrees a step.
Q LimitTurn(Q q, double limit) {
    const double w = q.w;
    double       c[3] { q.x / w, q.y / w, q.z / w };
    for (double& v : c) {
        double a = std::min(std::atan(v) * kRadToDeg * 2.0, limit);
        if (-limit > a) a = -limit;
        v = std::tan(a * kDegToRad * 0.5);
    }
    return Normalized(Q { 1.0, c[0], c[1], c[2] });
}
// The fmodf wrap of the spring path (0x1402031c4): into [-pi, pi).
double Wrap(double a) {
    return a >= 0.0 ? std::fmod(a + kPi, 2.0 * kPi) - kPi : std::fmod(a - kPi, 2.0 * kPi) + kPi;
}
V3 Of(const linalg::Vector3f& v) { return { v.x(), v.y(), v.z() }; }

// Rotation: the angle limits (la), then the angular velocity takes back what they cut.
void LimitAngles(const WPPuppet::BoneSimulation& sim, V3& e, Q& q) {
    const V3 before = e;
    for (int i = 0; i < 3; i++) {
        e[i] = std::max(e[i], static_cast<double>(sim.angle_min[i]));
        e[i] = std::min(e[i], static_cast<double>(sim.angle_max[i]));
    }
    q = Mul(Conj(FromAngles(Sub(before, e))), q);
}

// Translation: the held axes (tax/tay/taz false) along the bone's world axes, then the tm cap.
V3 HoldAndCap(const WPPuppet::BoneSimulation& sim, V3 x, const M3& axes, double layer_scale) {
    using S = WPPuppet::BoneSimulation;
    const uint32_t hold[3] { S::kHoldMoveX, S::kHoldMoveY, S::kHoldMoveZ };
    for (int i = 0; i < 3; i++) {
        if ((sim.flags & hold[i]) == 0) continue;
        const V3     a = Column(axes, i);
        const double d = Dot(a, a);
        if (d > 0.0) x = Sub(x, Scale(a, Dot(x, a) / d));
    }
    const double cap = layer_scale * sim.trans_max;
    if (cap > 0.0 && cap * cap < Dot(x, x)) x = Scale(x, cap / Length(x));
    return x;
}
} // namespace

PhysicsMatrix StepBonePhysics(const WPPuppet::BoneSimulation& sim, BonePhysicsState& state,
                              const PhysicsMatrix& current, const PhysicsMatrix& previous,
                              double layer_scale, double dt) noexcept {
    using S = WPPuppet::BoneSimulation;
    const M3 a = Linear(current);
    M3       inv {};
    PhysicsMatrix out { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    if (! Inverse(a, inv)) return out; // a collapsed bone: nothing can be measured in its space

    const V3 origin { current[12], current[13], current[14] };
    const V3 prev_origin { previous[12], previous[13], previous[14] };
    const V3 tp = Of(sim.tip);
    V3       x  = state.offset;
    V3       e  = state.angles;
    Q        q { state.rotation_velocity[0], state.rotation_velocity[1], state.rotation_velocity[2],
          state.rotation_velocity[3] };
    V3       vel = state.velocity;
    const bool turn = (sim.flags & S::kRotation) != 0, move = (sim.flags & S::kTranslation) != 0;

    // Where the tip was last step, seen from this step's animated bone, and where it is now.
    const V3 prev_tip  = Apply(inv, Sub(Add(Apply(Linear(previous), tp), prev_origin), origin));
    const V3 prev_dir  = Normalized(prev_tip);
    const V3 turned_tp = Apply(MatrixOf(e), tp);
    V3       tip       = Add(turned_tp, Apply(inv, x));
    if ((sim.flags & S::kGravity) != 0) {
        const V3 g = Scale(Apply(inv, Of(sim.gravity)), sim.mass * layer_scale);
        const V3 n = Normalized(turned_tp);
        tip        = Sub(tip, Sub(g, Scale(n, Dot(g, n))));
        if (move) vel = Add(vel, Scale(Of(sim.gravity), sim.mass * dt * 1000.0));
    }
    const double moved   = std::min(Length(Sub(tip, prev_tip)), 900.0 * dt);
    const V3     now_dir = Normalized(tip);
    // A tip the bone has none of (tp 0) gives no direction to turn by.
    const Q      back    = Dot(now_dir, now_dir) > 0.0 && Dot(prev_dir, prev_dir) > 0.0 ? Rotation(now_dir, prev_dir) : Q {};
    const double inertia = std::min(moved * sim.rot_inertia * kDegToRad, 1.0);
    const double friction_turn = std::min(dt * sim.rot_friction, 1.0);
    const double friction_move = std::min(dt * sim.trans_friction, 1.0);
    const double steps         = std::min(dt * kStepRate, 1.0);
    const uint32_t hold_turn[3] { S::kHoldTurnX, S::kHoldTurnY, S::kHoldTurnZ };

    if ((sim.flags & S::kRigid) != 0) {
        if (turn) {
            q = Mul(q, Slerp({}, back, inertia));
            if ((sim.flags & S::kTorqueLimit) != 0) q = LimitTurn(q, sim.torque_max);
            e = AnglesOf(Mul(MatrixOf(Slerp({}, q, steps)), MatrixOf(e)));
            if ((sim.flags & S::kAngleLimit) != 0) LimitAngles(sim, e, q);
            for (int i = 0; i < 3; i++)
                if ((sim.flags & hold_turn[i]) != 0) e[i] = 0.0;
            q = Slerp(q, {}, friction_turn);
        }
        if (move) {
            x   = Add(Sub(x, Scale(Sub(Add(x, origin), prev_origin), sim.trans_inertia)), Scale(vel, dt));
            x   = HoldAndCap(sim, x, a, layer_scale);
            vel = Sub(vel, Scale(vel, friction_move));
        }
    } else if ((sim.flags & S::kSpring) != 0) {
        if (turn) {
            q = Mul(q, Slerp({}, back, inertia));
            const double pull = std::min(sim.rot_stiffness * kDegToRad * dt, 1.0);
            q = Mul(q, Slerp({}, FromAngles(Scale(e, -1.0)), pull));
            if ((sim.flags & S::kTorqueLimit) != 0) q = LimitTurn(q, sim.torque_max);
            e = AnglesOf(Mul(MatrixOf(Slerp({}, q, steps)), MatrixOf(e)));
            for (int i = 0; i < 3; i++) e[i] = (sim.flags & hold_turn[i]) != 0 ? 0.0 : Wrap(e[i]);
            if ((sim.flags & S::kAngleLimit) != 0) LimitAngles(sim, e, q);
            q = Slerp(q, {}, friction_turn);
        }
        if (move) {
            const V3 rest = Sub(x, Scale(Sub(Add(x, origin), prev_origin), sim.trans_inertia));
            const V3 v1   = Sub(vel, Scale(rest, dt * sim.trans_stiffness));
            x             = HoldAndCap(sim, Add(rest, Scale(v1, dt)), a, layer_scale);
            vel           = Sub(v1, Scale(v1, friction_move));
        }
    }

    const bool finite = std::isfinite(q.w) && std::isfinite(q.x) && std::isfinite(q.y) && std::isfinite(q.z) &&
                        std::all_of(e.begin(), e.end(), [](double v) { return std::isfinite(v); }) &&
                        std::all_of(x.begin(), x.end(), [](double v) { return std::isfinite(v); }) &&
                        std::all_of(vel.begin(), vel.end(), [](double v) { return std::isfinite(v); });
    if (! finite) return out; // keep the last finite state
    if (turn) {
        state.rotation_velocity = { q.w, q.x, q.y, q.z };
        state.angles            = e;
    }
    if (move) {
        state.offset   = x;
        state.velocity = vel;
    }

    // 0x140202449: the model matrix is multiplied by [R(angles) | inverse(A) * offset].
    const M3 r   = MatrixOf(state.angles);
    const V3 off = Apply(inv, state.offset);
    for (int c = 0; c < 3; c++)
        for (int row = 0; row < 3; row++) out[c * 4 + row] = r[c * 3 + row];
    for (int row = 0; row < 3; row++) out[12 + row] = off[row];
    return out;
}

void ApplyBonePhysicsImpulse(BonePhysicsState& state, const std::array<double, 3>& linear,
                             const std::array<double, 3>& angular_degrees) noexcept {
    for (int i = 0; i < 3; i++) state.velocity[i] += linear[i];
    const Q turn = FromAngles(Scale(angular_degrees, kDegToRad));
    const Q q    = Mul(Q { state.rotation_velocity[0], state.rotation_velocity[1], state.rotation_velocity[2],
                         state.rotation_velocity[3] },
                       turn);
    state.rotation_velocity = { q.w, q.x, q.y, q.z };
}

bool ParseBoneSimulation(std::string_view text, WPPuppet::BoneSimulation& out) {
    using S = WPPuppet::BoneSimulation;
    out = S {};
    nlohmann::json json;
    if (text.empty() || ! wpscene::ParseBoundedJson(std::string(text), json) || ! json.is_object()) return false;
    // rapidjson's checks: a flag is a JSON true, a number any JSON number, a vector a "x y z" string.
    const auto on = [&](const char* key) {
        const auto it = json.find(key);
        return it != json.end() && it->is_boolean() && it->get<bool>();
    };
    const auto number = [&](const char* key, float& value) {
        const auto it = json.find(key);
        if (it != json.end() && it->is_number()) value = it->get<float>();
        return it != json.end() && it->is_number();
    };
    // atof per lane, lanes separated by spaces, the lanes zeroed first (0x140265f2a).
    const auto vector = [&](const char* key, linalg::Vector3f& value) {
        const auto it = json.find(key);
        if (it == json.end() || ! it->is_string()) return false;
        value                  = linalg::Vector3f(0.0f, 0.0f, 0.0f);
        const std::string word = it->get<std::string>();
        const char*       p    = word.c_str();
        for (int lane = 0; lane < 3 && *p != '\0'; lane++) {
            value[lane] = static_cast<float>(std::atof(p));
            while (*p != '\0' && *p != ' ') ++p;
            while (*p == ' ') ++p;
        }
        return true;
    };
    const auto flag = [&](const char* key, uint32_t bit) {
        if (on(key)) out.flags |= bit;
    };
    flag("ik", S::kIk);
    flag("ikce", S::kIkChainEnd);
    flag("r", S::kRotation);
    flag("t", S::kTranslation);
    flag("se", S::kSpring);
    flag("re", S::kRigid);
    const bool simulated = out.simulates();
    const bool ik        = (out.flags & S::kIk) != 0;
    if (simulated || ik) {
        flag("ge", S::kGravity);
        vector("gd", out.gravity);
        number("m", out.mass);
        number("tf", out.trans_friction);
        if (simulated) {
            number("rs", out.rot_stiffness);
            number("ts", out.trans_stiffness);
            number("rf", out.rot_friction);
            float inertia = 0.0f;
            if (number("ri", inertia)) out.rot_inertia = 1.0f - inertia / 100.0f;
            if (number("ti", inertia)) out.trans_inertia = 1.0f - inertia / 100.0f;
            out.tip_length = vector("tp", out.tip) ? out.tip.norm() / 100.0f : 1.0f;
            number("tm", out.trans_max);
            if (on("la")) {
                out.flags |= S::kAngleLimit;
                vector("lamin", out.angle_min);
                vector("lamax", out.angle_max);
            }
            if (on("lt")) {
                out.flags |= S::kTorqueLimit;
                number("ltmax", out.torque_max);
            }
            // An axis is held only when all three of its keys are bools.
            const auto axes = [&](const char* kx, const char* ky, const char* kz, uint32_t first) {
                const char* keys[3] { kx, ky, kz };
                for (const char* key : keys) {
                    const auto it = json.find(key);
                    if (it == json.end() || ! it->is_boolean()) return;
                }
                for (int i = 0; i < 3; i++)
                    if (! json[keys[i]].get<bool>()) out.flags |= first << i;
            };
            axes("rax", "ray", "raz", S::kHoldTurnX);
            axes("tax", "tay", "taz", S::kHoldMoveX);
            return true;
        }
        const float f        = out.trans_friction / 100.0f;
        out.trans_friction   = std::clamp(f * f, 0.0f, 1.0f);
        const auto depth = json.find("ikd");
        if (depth != json.end() && depth->is_number()) out.ik_depth = std::max(1, depth->get<int>());
        flag("ikg", S::kIkGravity);
        if (on("ikr")) {
            out.flags |= S::kIkRope;
            float damping = 0.0f;
            if (number("ikrd", damping)) out.ik_rope_damping = std::max(damping, 1.0f);
        }
        flag("ikse", S::kIkStretch);
        flag("ikfe", S::kIkFreeEnd);
        return true;
    }
    if ((out.flags & S::kIkChainEnd) != 0) {
        number("ikrminl", out.ik_rope_min_length);
        number("ikrmaxl", out.ik_rope_max_length);
        return true;
    }
    out.flags = 0;
    return false;
}

} // namespace wallpaper
