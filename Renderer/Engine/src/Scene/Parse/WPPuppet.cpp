// Clean-room implementation from the WallpaperMachine spec p5-models-puppets.md; written without access to the original source.
#include "WPPuppet.hpp"
#include "WPPuppetIk.hpp"
#include "WPPuppetPhysics.hpp"

#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <limits>

#include "Utils/Logging.h"

using namespace wallpaper;
using namespace wallpaper::linalg;

namespace
{
// Pose arithmetic runs in double precision on small private types; only the
// final matrices are converted back to the float affines the renderer consumes.
struct Quat {
    double w { 1.0 }, x { 0.0 }, y { 0.0 }, z { 0.0 };
};

Quat Mul(const Quat& a, const Quat& b) {
    return { a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
             a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
             a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
             a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w };
}
Quat   Conj(const Quat& a) { return { a.w, -a.x, -a.y, -a.z }; }
double Dot(const Quat& a, const Quat& b) { return a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z; }
Quat   Neg(const Quat& a) { return { -a.w, -a.x, -a.y, -a.z }; }
bool   Finite(const Quat& a) {
    return std::isfinite(a.w) && std::isfinite(a.x) && std::isfinite(a.y) && std::isfinite(a.z);
}
Quat Normalized(const Quat& a) {
    const double n = std::sqrt(Dot(a, a));
    if (! (n > 0.0) || ! std::isfinite(n)) return {};
    return { a.w / n, a.x / n, a.y / n, a.z / n };
}

// Wallpaper Engine's rotation blend (0x1401F9020, 0x1401F89A0, 0x1401F9820):
// a component lerp of `a` and `b`, `b` negated when the two point apart, then
// normalised. Weights outside 0..1 extrapolate the same way.
Quat Nlerp(const Quat& a, const Quat& b, double t) {
    const double k = Dot(a, b) < 0.0 ? -t : t;
    return Normalized({ (1.0 - t) * a.w + k * b.w, (1.0 - t) * a.x + k * b.x,
                        (1.0 - t) * a.y + k * b.y, (1.0 - t) * a.z + k * b.z });
}

// Bone tracks and IK target tracks occupy the same animation-layer blend stream in WE.
void BlendTrack(const WPPuppet::Animation::BoneTrack& track, idx ia, idx ib, double t,
                 double weight, bool additive, const std::array<double, 3>& ref_t,
                 const std::array<double, 3>& ref_s, const Quat& ref_q,
                 std::array<double, 3>& trans, std::array<double, 3>& scale, Quat& rot) {
    if ((track.unk & 1) != 0 || ia < 0 || ib < 0 || ! std::isfinite(t) ||
        static_cast<usize>(ia) >= track.frames.size() || static_cast<usize>(ib) >= track.frames.size()) return;
    const auto& fa = track.frames[static_cast<usize>(ia)];
    const auto& fb = track.frames[static_cast<usize>(ib)];
    const Quat qa { fa.quaternion.w(), fa.quaternion.x(), fa.quaternion.y(), fa.quaternion.z() };
    const Quat qb { fb.quaternion.w(), fb.quaternion.x(), fb.quaternion.y(), fb.quaternion.z() };
    std::array<double, 3> p, k;
    bool finite = Finite(qa) && Finite(qb);
    for (usize c = 0; c < 3; ++c) {
        const int ci = static_cast<int>(c);
        p[c] = fa.position(ci) + (fb.position(ci) - fa.position(ci)) * t;
        k[c] = fa.scale(ci) + (fb.scale(ci) - fa.scale(ci)) * t;
        finite = finite && std::isfinite(p[c]) && std::isfinite(k[c]);
    }
    if (! finite) return;
    const Quat sample_q = Nlerp(qa, qb, t);
    if (additive) {
        for (usize c = 0; c < 3; ++c) {
            trans[c] += (p[c] - ref_t[c]) * weight;
            scale[c] += (k[c] - ref_s[c]) * weight;
        }
        rot = Normalized(Mul(rot, Nlerp(Quat {}, Mul(Conj(ref_q), sample_q), weight)));
    } else if (weight == 1.0) {
        trans = p;
        scale = k;
        rot = sample_q;
    } else {
        for (usize c = 0; c < 3; ++c) {
            trans[c] = trans[c] * (1.0 - weight) + p[c] * weight;
            scale[c] = scale[c] * (1.0 - weight) + k[c] * weight;
        }
        rot = Nlerp(rot, sample_q, weight);
    }
}

// Euler angles in radians: z about z, after y about y, after x about x.
Quat FromEuler(double ex, double ey, double ez) {
    const Quat qx { std::cos(ex * 0.5), std::sin(ex * 0.5), 0, 0 };
    const Quat qy { std::cos(ey * 0.5), 0, std::sin(ey * 0.5), 0 };
    const Quat qz { std::cos(ez * 0.5), 0, 0, std::sin(ez * 0.5) };
    return Mul(qz, Mul(qy, qx));
}

struct Mat4 {
    std::array<double, 16> e {}; // column-major
    double& at(int r, int c) { return e[static_cast<usize>(c * 4 + r)]; }
    double  at(int r, int c) const { return e[static_cast<usize>(c * 4 + r)]; }
    static Mat4 Identity() {
        Mat4 m;
        for (int i = 0; i < 4; i++) m.at(i, i) = 1.0;
        return m;
    }
};

Mat4 Mul(const Mat4& a, const Mat4& b) {
    Mat4 m;
    for (int c = 0; c < 4; c++) {
        for (int r = 0; r < 4; r++) {
            double sum = 0.0;
            for (int k = 0; k < 4; k++) sum += a.at(r, k) * b.at(k, c);
            m.at(r, c) = sum;
        }
    }
    return m;
}

Mat4 Compose(const std::array<double, 3>& t, const Quat& q, const std::array<double, 3>& s) {
    const double xx = q.x * q.x, yy = q.y * q.y, zz = q.z * q.z;
    const double xy = q.x * q.y, xz = q.x * q.z, yz = q.y * q.z;
    const double wx = q.w * q.x, wy = q.w * q.y, wz = q.w * q.z;
    Mat4         m  = Mat4::Identity();
    m.at(0, 0)      = (1 - 2 * (yy + zz)) * s[0];
    m.at(1, 0)      = (2 * (xy + wz)) * s[0];
    m.at(2, 0)      = (2 * (xz - wy)) * s[0];
    m.at(0, 1)      = (2 * (xy - wz)) * s[1];
    m.at(1, 1)      = (1 - 2 * (xx + zz)) * s[1];
    m.at(2, 1)      = (2 * (yz + wx)) * s[1];
    m.at(0, 2)      = (2 * (xz + wy)) * s[2];
    m.at(1, 2)      = (2 * (yz - wx)) * s[2];
    m.at(2, 2)      = (1 - 2 * (xx + yy)) * s[2];
    for (int i = 0; i < 3; i++) m.at(i, 3) = t[static_cast<usize>(i)];
    return m;
}

Mat4 FromAffine(const Affine3f& a) {
    Mat4 m = Mat4::Identity();
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 4; c++) m.at(r, c) = static_cast<double>(a(r, c));
    return m;
}

void ToAffine(const Mat4& m, Affine3f& a) {
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 4; c++) a(r, c) = static_cast<float>(m.at(r, c));
    a(3, 0) = 0.0f;
    a(3, 1) = 0.0f;
    a(3, 2) = 0.0f;
    a(3, 3) = 1.0f;
}

// Inverse of an affine matrix; false when the linear part is singular (a zero
// scale axis somewhere in the chain) or the result would not be finite.
bool InvertAffine(const Mat4& m, Mat4& out) {
    const double a = m.at(0, 0), b = m.at(0, 1), c = m.at(0, 2);
    const double d = m.at(1, 0), e = m.at(1, 1), f = m.at(1, 2);
    const double g = m.at(2, 0), h = m.at(2, 1), i = m.at(2, 2);
    const double c00 = e * i - f * h, c01 = f * g - d * i, c02 = d * h - e * g;
    const double det = a * c00 + b * c01 + c * c02;
    auto         len = [&](int col) {
        return std::sqrt(m.at(0, col) * m.at(0, col) + m.at(1, col) * m.at(1, col) +
                         m.at(2, col) * m.at(2, col));
    };
    const double scale = len(0) * len(1) * len(2);
    if (! std::isfinite(det) || ! (scale > 0.0) || std::abs(det) <= 1e-12 * scale) return false;
    const double inv = 1.0 / det;
    out              = Mat4::Identity();
    out.at(0, 0)     = c00 * inv;
    out.at(0, 1)     = (c * h - b * i) * inv;
    out.at(0, 2)     = (b * f - c * e) * inv;
    out.at(1, 0)     = c01 * inv;
    out.at(1, 1)     = (a * i - c * g) * inv;
    out.at(1, 2)     = (c * d - a * f) * inv;
    out.at(2, 0)     = c02 * inv;
    out.at(2, 1)     = (b * g - a * h) * inv;
    out.at(2, 2)     = (a * e - b * d) * inv;
    for (int r = 0; r < 3; r++) {
        out.at(r, 3) = -(out.at(r, 0) * m.at(0, 3) + out.at(r, 1) * m.at(1, 3) +
                         out.at(r, 2) * m.at(2, 3));
    }
    for (const double v : out.e)
        if (! std::isfinite(v)) return false;
    return true;
}

Quat QuatFromRotation(const double r[3][3]) {
    const double trace = r[0][0] + r[1][1] + r[2][2];
    Quat         q;
    if (trace > 0.0) {
        const double s = std::sqrt(trace + 1.0) * 2.0;
        q              = { 0.25 * s, (r[2][1] - r[1][2]) / s, (r[0][2] - r[2][0]) / s,
                           (r[1][0] - r[0][1]) / s };
    } else if (r[0][0] > r[1][1] && r[0][0] > r[2][2]) {
        const double s = std::sqrt(1.0 + r[0][0] - r[1][1] - r[2][2]) * 2.0;
        q              = { (r[2][1] - r[1][2]) / s, 0.25 * s, (r[0][1] + r[1][0]) / s,
                           (r[0][2] + r[2][0]) / s };
    } else if (r[1][1] > r[2][2]) {
        const double s = std::sqrt(1.0 + r[1][1] - r[0][0] - r[2][2]) * 2.0;
        q              = { (r[0][2] - r[2][0]) / s, (r[0][1] + r[1][0]) / s, 0.25 * s,
                           (r[1][2] + r[2][1]) / s };
    } else {
        const double s = std::sqrt(1.0 + r[2][2] - r[0][0] - r[1][1]) * 2.0;
        q              = { (r[1][0] - r[0][1]) / s, (r[0][2] + r[2][0]) / s,
                           (r[1][2] + r[2][1]) / s, 0.25 * s };
    }
    if (! Finite(q)) return {};
    return Normalized(q);
}

// Pending end-of-animation notices are kept only up to this many (the spec
// asks for at least 64; one and a half times that leaves headroom for a
// scene that drains the queue once per several frames).
constexpr usize kFinishQueueCapacity = 64 + 64 / 2;

// Appends a notice for the layer numbered `serial`; a full queue drops it.
void PostFinishNotice(std::vector<i32>& queue, i32 serial) {
    if (queue.size() >= kFinishQueueCapacity) return;
    queue.push_back(serial);
}

// Whether a layer's clock ended a cycle in this step, as the composer
// 0x1401FDF90 sets the ended flag 0x4000000: a looping clip when its clock wrapped (the time
// went down), a mirrored clip when it turned (our mirror clock runs over 2L, the turn is a
// change of half). A single clip ends at its end (HasReachedEnd).
bool EndedACycle(const WPPuppet::Animation& anim, double before, double after) {
    if (anim.mode == WPPuppet::PlayMode::Loop) return after < before;
    if (anim.mode == WPPuppet::PlayMode::Mirror) return (before > anim.max_time) != (after > anim.max_time);
    return false;
}

// True when `layer` is a running single-shot animation whose clock has
// reached or passed its duration.
bool HasReachedEnd(const WPPuppetLayer::AnimationLayer& layer, const WPPuppet::Animation* anim) {
    if (anim == nullptr || anim->mode != WPPuppet::PlayMode::Single) return false;
    if (! layer.playing) return false;
    return anim->max_time > 0.0 && layer.cur_time >= anim->max_time;
}

// The rotation sub_140267F00 mixes two key frames with: the shorter way round, spherical while
// the frames are more than about 0.026 degrees apart, a plain (unnormalised) lerp below that.
Quat WeSlerp(const Quat& a, Quat b, double t) {
    double d = Dot(a, b);
    if (d < 0.0) {
        b = Neg(b);
        d = -d;
    }
    if (d <= 0.9999999) {
        const double angle = std::acos(d);
        const double s     = std::sin(angle);
        const double ka    = std::sin((1.0 - t) * angle) / s;
        const double kb    = std::sin(t * angle) / s;
        return { a.w * ka + b.w * kb, a.x * ka + b.x * kb, a.y * ka + b.y * kb, a.z * ka + b.z * kb };
    }
    return { a.w * (1.0 - t) + b.w * t, a.x * (1.0 - t) + b.x * t, a.y * (1.0 - t) + b.y * t,
             a.z * (1.0 - t) + b.z * t };
}

// The root-motion bone matrix: the bone's model matrix from `frames`'s tracks at frames a and b
// mixed by t (sub_140267F00; sub_140267580 is the one-frame case), walking its animation
// parents. Each local is the frame's translation and rotation; scale is left out. A bone the
// clip holds no usable frame for takes its reference placement.
Mat4 BoneModelMatrix(const WPPuppet& puppet, const WPPuppet::Animation& frames, uint32_t bone, idx a,
                     idx b, double t) {
    Mat4  acc   = Mat4::Identity();
    usize steps = 0;
    for (uint32_t i = bone; i != WPPuppet::NO_PARENT && i < puppet.bones.size() && steps <= puppet.bones.size();
         i = puppet.bones[i].anim_parent, ++steps) {
        const auto&           info = puppet.bones[i];
        std::array<double, 3> trans { info.reference_position(0), info.reference_position(1),
                                      info.reference_position(2) };
        const auto&           rq = info.reference_rotation;
        Quat                  rot { rq.w(), rq.x(), rq.y(), rq.z() };
        if (i < frames.bone_tracks.size()) {
            const auto& list = frames.bone_tracks[i].frames;
            if (a >= 0 && b >= 0 && static_cast<usize>(a) < list.size() && static_cast<usize>(b) < list.size()) {
                const auto& fa = list[static_cast<usize>(a)];
                const auto& fb = list[static_cast<usize>(b)];
                for (int c = 0; c < 3; c++) {
                    trans[static_cast<usize>(c)] = fa.position(c) + (fb.position(c) - fa.position(c)) * t;
                }
                rot = WeSlerp({ fa.quaternion.w(), fa.quaternion.x(), fa.quaternion.y(), fa.quaternion.z() },
                              { fb.quaternion.w(), fb.quaternion.x(), fb.quaternion.y(), fb.quaternion.z() }, t);
            }
        }
        acc = Mul(Compose(trans, rot, { 1.0, 1.0, 1.0 }), acc);
    }
    return acc;
}

// 3x3 matrices of the root-motion arithmetic, column-major (m[column * 3 + row]).
using M3 = std::array<double, 9>;
M3 Linear(const Mat4& m) {
    M3 out {};
    for (int c = 0; c < 3; c++)
        for (int r = 0; r < 3; r++) out[static_cast<usize>(c * 3 + r)] = m.at(r, c);
    return out;
}
M3 Linear(const std::array<double, 16>& e) {
    M3 out {};
    for (usize c = 0; c < 3; c++)
        for (usize r = 0; r < 3; r++) out[c * 3 + r] = e[c * 4 + r];
    return out;
}
M3 Mul3(const M3& a, const M3& b) {
    M3 out {};
    for (usize c = 0; c < 3; c++)
        for (usize r = 0; r < 3; r++)
            for (usize k = 0; k < 3; k++) out[c * 3 + r] += a[k * 3 + r] * b[c * 3 + k];
    return out;
}
// sub_140228B00: the cofactor inverse (no singularity guard there either; a singular input gives
// non-finite values, which the callers' finite checks drop).
M3 Inverse3(const M3& m) {
    const double a = m[0], b = m[3], c = m[6], d = m[1], e = m[4], f = m[7], g = m[2], h = m[5], i = m[8];
    const double co00 = e * i - f * h, co01 = f * g - d * i, co02 = d * h - e * g;
    const double inv  = 1.0 / (a * co00 + b * co01 + c * co02);
    M3           out {};
    out[0] = co00 * inv;
    out[1] = co01 * inv;
    out[2] = co02 * inv;
    out[3] = (c * h - b * i) * inv;
    out[4] = (a * i - c * g) * inv;
    out[5] = (b * g - a * h) * inv;
    out[6] = (b * f - c * e) * inv;
    out[7] = (c * d - a * f) * inv;
    out[8] = (a * e - b * d) * inv;
    return out;
}
std::array<double, 3> Apply3(const M3& m, const std::array<double, 3>& v) {
    std::array<double, 3> out {};
    for (usize r = 0; r < 3; r++) out[r] = m[r] * v[0] + m[3 + r] * v[1] + m[6 + r] * v[2];
    return out;
}
// sub_140225900's yaw: the turn about y that carries +z to the matrix's third column laid flat
// (columns (z, 0, -x), (0, 1, 0), (x, 0, z) of the normalised (x, 0, z)).
M3 YawOf(const M3& m) {
    const double len = std::sqrt(m[6] * m[6] + m[8] * m[8]);
    if (! (len > 0.0) || ! std::isfinite(len)) return { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    const double x = m[6] / len, z = m[8] / len;
    return { z, 0, -x, 0, 1, 0, x, 0, z };
}

// One layer's root-motion lock on its root bone, applied after that layer's sample.
struct RootLock {
    bool                  active { false };
    uint32_t              bone { WPPuppet::NO_PARENT };
    uint32_t              flags { 0 };
    double                weight { 0.0 };
    std::array<double, 3> start_t {};
    std::array<double, 3> sample_t {};
    M3                    turn {};   // Q: the inverse of the clip's yaw so far
    Quat                  turn_q {};
};

// we_AnimLayerEffectiveBlend 0x14026C8B0 at layer time `t` (see updateWeights); `clear` tells
// whether a looping or mirrored clip's blend-in has completed.
double EffectiveBlend(const WPPuppetLayer::AnimationLayer& authored, const WPPuppet::Animation& anim,
                      double t, bool* clear) {
    constexpr double kTiny = 1.1920928955078125e-7;
    const double     dur   = anim.max_time;
    if (anim.mode == WPPuppet::PlayMode::Mirror && t > dur) t = 2.0 * dur - t;
    const double reach = std::min(dur, authored.blendtime);
    const double den   = std::min(dur * 0.5, authored.blendtime);
    double       w     = authored.blend;
    if (authored.blendin) {
        double f = reach <= kTiny ? 1.0 : t / den;
        if (f > 1.0) f = 1.0;
        w = f * authored.blend;
        if (clear != nullptr) *clear = anim.mode != WPPuppet::PlayMode::Single && f >= 1.0;
    }
    if (authored.blendout && reach > kTiny) {
        const double g = (dur - t) / den;
        if (g <= 1.0) w *= g;
    }
    return w;
}

// The time a layer's clip is at, as Wallpaper Engine's clock reads it: a mirrored clip's clock
// bounces inside one pass.
double ClipTime(const WPPuppet::Animation& anim, double t) {
    return anim.mode == WPPuppet::PlayMode::Mirror && t > anim.max_time ? 2.0 * anim.max_time - t : t;
}

// At most this many root-motion steps wait for their owner; a puppet nobody drains drops the rest.
constexpr usize kRootMotionQueueCapacity = 64;
} // namespace

namespace
{
// The frames a clip plays: a clip record without its own frames plays its source's from the
// record's start on (0x14021C480 @0x14021c6be: frames += start, anim = source).
const WPPuppet::Animation& PlayedFrames(const WPPuppet& puppet, const WPPuppet::Animation& anim,
                                        idx& offset) {
    offset = 0;
    if ((anim.flags & (WPPuppet::kAnimClip | WPPuppet::kAnimOwnFrames)) == WPPuppet::kAnimClip &&
        anim.clip.has_value() && anim.clip->source < puppet.anims.size()) {
        offset = static_cast<idx>(anim.clip->start);
        return puppet.anims[anim.clip->source];
    }
    return anim;
}
} // namespace

void WPPuppet::prepared() {
    const usize count = bones.size();
    std::vector<Mat4> world(count);
    for (usize i = 0; i < count; i++) {
        auto& bone = bones[i];
        // A parent has to come earlier in the array; anything else is a root.
        if (bone.bind_parent != NO_PARENT && bone.bind_parent >= i) {
            LOG_ERROR("puppet bone %zu names bind parent %u that is not before it; treated as a root",
                      i, bone.bind_parent);
            bone.bind_parent = NO_PARENT;
            bone.parent      = NO_PARENT;
        }
        const Mat4 local = FromAffine(bone.local_bind);
        if (bone.bind_parent == NO_PARENT) {
            world[i] = local;
            if (world_anchored_bones) {
                Mat4 anchor = Mat4::Identity();
                for (int k = 0; k < 3; k++) {
                    anchor.at(k, 3) = static_cast<double>(bone.vertex_centroid_offset(k));
                }
                world[i] = Mul(anchor, local);
            }
        } else {
            world[i] = Mul(world[bone.bind_parent], local);
        }
        ToAffine(world[i], bone.world_bind);
        Mat4 inverse;
        if (InvertAffine(world[i], inverse)) {
            ToAffine(inverse, bone.inv_bind);
        } else {
            LOG_INFO("puppet bone %zu has a singular bind transform; using an identity inverse", i);
            bone.inv_bind = Affine3f::Identity();
        }

        // Rest placement: the stored reference pose when there is one, else the bind.
        const Affine3f& ref = bone.has_local_reference ? bone.local_reference : bone.local_bind;
        double          col[3][3];
        double          len[3];
        for (int c = 0; c < 3; c++) {
            for (int r = 0; r < 3; r++) col[c][r] = static_cast<double>(ref(r, c));
            len[c] = std::sqrt(col[c][0] * col[c][0] + col[c][1] * col[c][1] + col[c][2] * col[c][2]);
        }
        const double det = col[0][0] * (col[1][1] * col[2][2] - col[2][1] * col[1][2]) -
                           col[1][0] * (col[0][1] * col[2][2] - col[2][1] * col[0][2]) +
                           col[2][0] * (col[0][1] * col[1][2] - col[1][1] * col[0][2]);
        double sx = len[0];
        double flip = 1.0;
        if (det < 0.0) {
            sx   = -sx;
            flip = -1.0;
        }
        double rot[3][3];
        for (int c = 0; c < 3; c++) {
            const double k = c == 0 ? flip : 1.0;
            for (int r = 0; r < 3; r++) {
                rot[r][c] = len[c] > 0.0 ? col[c][r] / len[c] * k : col[c][r];
            }
        }
        const Quat q = QuatFromRotation(rot);
        for (int k = 0; k < 3; k++) bone.reference_position(k) = ref(k, 3);
        bone.reference_scale = Vector3f(static_cast<float>(sx), static_cast<float>(len[1]),
                                        static_cast<float>(len[2]));
        bone.reference_rotation = Quaterniond(q.w, q.x, q.y, q.z);
    }

    for (auto& anim : anims) {
        const bool usable = std::isfinite(anim.fps) && anim.fps > 0.0 && anim.length > 0;
        anim.frame_time   = usable ? 1.0 / anim.fps : 0.0;
        anim.max_time     = usable ? static_cast<double>(anim.length) / anim.fps : 0.0;
        for (auto* tracks : { &anim.bone_tracks, &anim.target_tracks }) {
            for (auto& track : *tracks) {
                for (auto& frame : track.frames) {
                    const Quat q = FromEuler(frame.angle.x(), frame.angle.y(), frame.angle.z());
                    frame.quaternion = Quaterniond(q.w, q.x, q.y, q.z);
                }
            }
        }
    }
    // 0x1402651b1..0x140265348: a root-motion clip keeps its root bone's model matrix at its
    // first and last frames and the inverse of the first's 3x3. With its own frames those are
    // frames 0 and length of its own tracks, else start and end of its source's.
    for (auto& anim : anims) {
        if (! anim.clip.has_value() || (anim.flags & kRootMotionMask) == 0) continue;
        auto& clip = *anim.clip;
        if (clip.bone == NO_PARENT || clip.bone >= bones.size() || clip.source >= anims.size()) continue;
        const bool  own    = (anim.flags & kAnimOwnFrames) != 0;
        const auto& frames = own ? anim : anims[clip.source];
        const idx   first  = own ? 0 : static_cast<idx>(clip.start);
        const idx   last   = own ? static_cast<idx>(std::max(anim.length, 0)) : static_cast<idx>(clip.end);
        const Mat4  s      = BoneModelMatrix(*this, frames, clip.bone, first, first, 0.0);
        const Mat4  e      = BoneModelMatrix(*this, frames, clip.bone, last, last, 0.0);
        clip.start_matrix  = s.e;
        clip.end_matrix    = e.e;
        clip.start_inverse = Inverse3(Linear(s));
        clip.prepared = std::all_of(clip.start_inverse.begin(), clip.start_inverse.end(),
                                    [](double v) { return std::isfinite(v); });
        if (! clip.prepared) {
            LOG_INFO("animation %d: its root bone's first frame cannot be inverted; it moves no layer",
                     anim.id);
        }
    }
    has_simulation = std::any_of(bones.begin(), bones.end(),
                                 [](const Bone& bone) { return bone.simulation.simulates(); });
    ik_plan = PreparePuppetIk(*this);
}

void WPPuppet::evaluatePose(const WPPuppetLayer& pose_layer,
                            std::span<linalg::Affine3f> out) const noexcept {
    if (! pose_layer.m_state) return;
    auto&        state = *pose_layer.m_state;
    const usize  count = std::min(bones.size(), out.size());

    // What each layer plays: its clip's frames, or its source's from the clip's start on.
    const usize layer_count = state.m_layers.size();
    thread_local std::vector<const Animation*> played;
    thread_local std::vector<idx>              offsets;
    thread_local std::vector<RootLock>         locks;
    played.assign(layer_count, nullptr);
    offsets.assign(layer_count, 0);
    locks.assign(layer_count, RootLock {});
    for (usize k = 0; k < layer_count; k++) {
        const auto& layer = state.m_layers[k];
        if (layer.anim != nullptr) played[k] = &PlayedFrames(*this, *layer.anim, offsets[k]);
    }

    // Root motion (0x14021C480 @0x14021cbf8 -> sub_140225900), one extraction per visible layer
    // of a `rootmotion` model whose clip carries root-motion bits. A layer that weighs nothing
    // or extracts nothing loses its priming; the call is skipped, priming kept, while the
    // absolute layers above leave it no more than 1e-4 of the pose.
    for (usize k = 0; k < layer_count; k++) {
        auto& layer = state.m_layers[k];
        if (layer.anim == nullptr || ! layer.anim_layer.visible) continue;
        const auto& anim = *layer.anim;
        if (layer.blend == 0.0 || ! state.m_root_motion || (anim.flags & kRootMotionMask) == 0) {
            layer.rm_primed = false;
            continue;
        }
        double later = 1.0;
        for (usize j = k + 1; j < layer_count; j++) {
            const auto& above = state.m_layers[j];
            if (above.anim == nullptr || ! above.anim_layer.visible || above.anim_layer.additive) continue;
            later *= 1.0 - above.pre_step_blend;
        }
        const double now = ClipTime(anim, layer.anim_layer.cur_time);
        const double t   = layer.interp_info.t;
        if (later > 0.0001 && anim.clip.has_value() && anim.clip->prepared && std::isfinite(t)) {
            const auto& clip   = *anim.clip;
            const auto& frames = *played[k];
            const idx   ia     = layer.interp_info.frame_a + offsets[k];
            const idx   ib     = layer.interp_info.frame_b + offsets[k];
            const Mat4  m      = BoneModelMatrix(*this, frames, clip.bone, ia, ib, t);
            const auto& s      = clip.start_matrix;
            const std::array<double, 3> start_t { s[12], s[13], s[14] };
            const std::array<double, 3> sample_t { m.at(0, 3), m.at(1, 3), m.at(2, 3) };
            // Ry: the clip's yaw since its first frame; Q its inverse (WE composes Q as
            // yaw(S3 * S3^-1) * Ry^-1, whose first factor is the identity).
            const M3 ry = YawOf(Mul3(Linear(m), clip.start_inverse));
            const M3 q  = Inverse3(ry);

            auto& lock    = locks[k];
            lock.active   = true;
            lock.bone     = clip.bone;
            lock.flags    = anim.flags;
            lock.weight   = layer.blend;
            lock.start_t  = start_t;
            lock.sample_t = sample_t;
            lock.turn     = q;
            double r[3][3];
            for (usize row = 0; row < 3; row++)
                for (usize col = 0; col < 3; col++) r[row][col] = q[col * 3 + row];
            lock.turn_q = QuatFromRotation(r);

            if (! layer.rm_primed) {
                // The first extraction measures from the clip's start, or from origin_offset
                // frames past it.
                if (clip.origin_offset == 0) {
                    layer.rm_prev = s;
                } else {
                    const idx f = (anim.flags & kAnimOwnFrames) != 0
                                      ? 0
                                      : static_cast<idx>(clip.origin_offset) + static_cast<idx>(clip.start);
                    layer.rm_prev = BoneModelMatrix(*this, frames, clip.bone, f, f, 0.0).e;
                }
            }
            const auto&           prev = layer.rm_prev;
            const std::array<double, 3> prev_t { prev[12], prev[13], prev[14] };
            M3                    p3 = Linear(prev);
            std::array<double, 3> wrap { 0.0, 0.0, 0.0 };
            if (layer.rm_prev_time > now) {
                // The clock went back (a loop, or a mirror's return): the last measure is
                // carried to before the clip's start, as if the clip had played on.
                const auto& e = clip.end_matrix;
                for (usize c = 0; c < 3; c++) wrap[c] = e[12 + c] - s[12 + c];
                p3 = Mul3(Mul3(p3, Inverse3(Linear(e))), Linear(s));
            }
            const M3 yp = YawOf(Mul3(p3, clip.start_inverse));

            WPPuppetLayer::RootMotionStep step;
            const double   gain = layer.blend * later;
            if ((anim.flags & (kRootX | kRootY | kRootZ)) != 0) {
                const auto            rs = Apply3(ry, start_t);
                const auto            ps = Apply3(yp, start_t);
                std::array<double, 3> d {};
                for (usize c = 0; c < 3; c++) d[c] = wrap[c] + (sample_t[c] - prev_t[c]) - rs[c] + ps[c];
                const auto qd = Apply3(q, d);
                step.translation = linalg::Vector3d((anim.flags & kRootX) != 0 ? qd[0] * gain : 0.0,
                                                    (anim.flags & kRootY) != 0 ? qd[1] * gain : 0.0,
                                                    (anim.flags & kRootZ) != 0 ? qd[2] * gain : 0.0);
            }
            if ((anim.flags & kRootYaw) != 0) {
                // glm's extractEulerAngleXYZ y angle of Yp^-1 * Ry.
                const M3 n = Mul3(Inverse3(yp), ry);
                step.yaw   = std::atan2(-n[2], std::sqrt(n[5] * n[5] + n[8] * n[8])) * gain;
            }
            const bool finite = step.translation.allFinite() && std::isfinite(step.yaw);
            if (finite && (step.translation.x() != 0.0 || step.translation.y() != 0.0 ||
                           step.translation.z() != 0.0 || step.yaw != 0.0) &&
                state.m_root_motion_steps.size() < kRootMotionQueueCapacity) {
                state.m_root_motion_steps.push_back(step);
            }
            layer.rm_prev = m.e;
        }
        layer.rm_primed    = true;
        layer.rm_prev_time = now;
    }

    if (state.m_morph != nullptr) {
        const bool model = state.m_composition == WPPuppetLayer::CompositionKind::Model;
        for (usize mesh = 0; mesh < state.m_morph->meshes.size(); ++mesh) {
            auto& morph = state.m_morph->meshes[mesh];
            std::fill(morph.weights.begin(), morph.weights.end(), 0.0f);
            std::fill(morph.active.begin(), morph.active.end(), uint8_t(0));
            morph.dirty = true;
            if (morph.weights.empty()) continue;
            for (usize k = 0; k < layer_count; ++k) {
                const auto& layer = state.m_layers[k];
                if (layer.anim == nullptr || !layer.anim_layer.visible || layer.blend == 0.0) continue;
                const auto& source = *played[k];
                if (mesh >= source.morph_tracks.size() || (source.morph_tracks[mesh].flags & 1u) == 0) continue;
                const idx ia = layer.interp_info.frame_a + offsets[k], ib = layer.interp_info.frame_b + offsets[k];
                if (ia < 0 || ib < 0 || !std::isfinite(layer.interp_info.t)) continue;
                for (const auto& curve : source.morph_tracks[mesh].curves) {
                    const usize shape = curve.shape;
                    if (shape >= morph.weights.size() || usize(std::max(ia, ib)) >= curve.values.size()) continue;
                    const double v = curve.values[ia] + (curve.values[ib] - curve.values[ia]) * layer.interp_info.t;
                    if (!std::isfinite(v)) continue;
                    const bool active = std::abs(v) >= std::numeric_limits<float>::epsilon();
                    auto& weight = morph.weights[shape];
                    if (!layer.anim_layer.additive && layer.blend == 1.0) {
                        morph.active[shape] = active;
                        if (active) weight = float(v);
                    } else if (!layer.anim_layer.additive) {
                        if (active) morph.active[shape] = true;
                        const double next = weight * (1.0 - layer.blend) + v * layer.blend;
                        weight = float(model ? std::clamp(next, 0.0, 1.0) : next);
                    } else if (active) {
                        morph.active[shape] = true;
                        const double delta = v * layer.blend, prior = weight;
                        weight = float(model ? std::clamp(prior + delta, 0.0, 1.0)
                                             : std::clamp(prior + delta, std::min(prior, delta), std::max(prior, delta)));
                    }
                }
            }
        }
    }

    if (bone_alpha) {
        // 0x1401FDF90: the skeleton's +616 array starts at 1 every evaluation, then each layer
        // pulls a bone toward its curve's value v by (v - 1) * weight, never past v or the
        // value below (a bone whose track is flagged off, flags & 3 == 1, keeps it).
        state.m_bone_alpha.assign(bones.size(), 1.0f);
        for (usize k = 0; k < layer_count; k++) {
            const auto& layer = state.m_layers[k];
            if (layer.anim == nullptr || ! layer.anim_layer.visible || layer.blend == 0.0) continue;
            const auto&  source = *played[k];
            const auto&  curves = source.blend_curves;
            const idx    ia = layer.interp_info.frame_a + offsets[k], ib = layer.interp_info.frame_b + offsets[k];
            const double t  = layer.interp_info.t;
            if (ia < 0 || ib < 0 || ! std::isfinite(t)) continue;
            for (usize b = 0; b < std::min(curves.size(), bones.size()); b++) {
                if (b < source.bone_tracks.size() && (source.bone_tracks[b].unk & 3) == 1) continue;
                const auto& values = curves[b].values;
                if (static_cast<usize>(std::max(ia, ib)) >= values.size()) continue;
                const double v = values[static_cast<usize>(ia)] +
                                 (values[static_cast<usize>(ib)] - values[static_cast<usize>(ia)]) * t;
                if (! std::isfinite(v)) continue;
                const double p = state.m_bone_alpha[b];
                state.m_bone_alpha[b] = static_cast<float>(
                    std::clamp(p + (v - 1.0) * layer.blend, std::min(p, v), std::max(p, v)));
            }
        }
    }
    if (state.m_ik != nullptr) {
        auto& ik = *state.m_ik;
        for (usize i = 0; i < ik.plan->targets.size(); ++i) {
            const auto& base = ik.plan->targets[i];
            const std::array<double, 3> ref_t { base.position.x(), base.position.y(), base.position.z() };
            const std::array<double, 3> ref_s { base.scale.x(), base.scale.y(), base.scale.z() };
            const Quat ref_q { base.rotation.w(), base.rotation.x(), base.rotation.y(), base.rotation.z() };
            auto trans = ref_t, scale = ref_s;
            auto rot = ref_q;
            for (usize k = 0; k < layer_count; ++k) {
                const auto& layer = state.m_layers[k];
                if (layer.anim == nullptr || ! layer.anim_layer.visible || layer.blend == 0) continue;
                const auto& source = *played[k];
                if (i >= source.target_tracks.size()) continue;
                BlendTrack(source.target_tracks[i], layer.interp_info.frame_a + offsets[k],
                           layer.interp_info.frame_b + offsets[k], layer.interp_info.t, layer.blend,
                           layer.anim_layer.additive, ref_t, ref_s, ref_q, trans, scale, rot);
            }
            ToAffine(Compose(trans, Normalized(rot), scale), ik.targets[i]);
        }
        if (! ik.link_weights.empty()) {
            bool first = true;
            for (usize k = 0; k < layer_count; ++k) {
                const auto& layer = state.m_layers[k];
                if (layer.anim == nullptr || ! layer.anim_layer.visible) continue;
                const bool   additive = layer.anim_layer.additive;
                const double blend    = layer.blend;
                // 0x1401fee49..0x1401fee87: the first partial/additive layer, or
                // one whose flag word is signed-negative, starts weights at zero.
                // Other full layers replace only their active curves.
                // Zero blend still clears that baseline, including a same-time write.
                if (first && (blend != 1 || additive || (layer.anim->flags & 0x80000000u) != 0))
                    std::fill(ik.link_weights.begin(), ik.link_weights.end(), 0);
                first              = false;
                const auto& source = *played[k];
                const idx   a      = layer.interp_info.frame_a + offsets[k],
                          b        = layer.interp_info.frame_b + offsets[k];
                const double t     = layer.interp_info.t;
                if (a < 0 || b < 0 || ! std::isfinite(t)) continue;
                for (usize slot = 0; slot < ik.plan->link_curve_indices.size(); ++slot) {
                    const auto index = ik.plan->link_curve_indices[slot];
                    if (index >= source.link_curves.size()) continue;
                    const auto& curve = source.link_curves[index];
                    if ((curve.flags & 1) != 0 ||
                        static_cast<usize>(std::max(a, b)) >= curve.values.size())
                        continue;
                    const double value = curve.values[a] + (curve.values[b] - curve.values[a]) * t;
                    if (! std::isfinite(value)) continue;
                    const double previous = ik.link_weights[slot];
                    const double mixed =
                        additive ? previous + value * blend : previous + (value - previous) * blend;
                    if (std::isfinite(mixed)) ik.link_weights[slot] = static_cast<float>(mixed);
                }
            }
        }
    }
    thread_local std::vector<Mat4> world;
    world.resize(count);
    bool reported_parent = false;
    usize next_bone_link = 0;

    for (usize i = 0; i < count; i++) {
        const auto& bone = bones[i];
        if (state.m_ik != nullptr && !state.m_ik->plan->driven.empty() && state.m_ik->plan->driven[i]) {
            // A flag-2 bone without its own chain keeps the solution written when the chain
            // root was visited (0x1402006d6); composing its masked track would erase the solve.
            world[i] = FromAffine(state.m_model_bones[i]);
            Mat4 local = world[i], inverse;
            if (bone.anim_parent < i && InvertAffine(world[bone.anim_parent], inverse)) local = Mul(inverse, world[i]);
            if (i < state.m_local_bones.size()) ToAffine(local, state.m_local_bones[i]);
            continue;
        }
        const std::array<double, 3> ref_t { bone.reference_position(0), bone.reference_position(1),
                                            bone.reference_position(2) };
        const std::array<double, 3> ref_s { bone.reference_scale(0), bone.reference_scale(1),
                                            bone.reference_scale(2) };
        const auto& rq = bone.reference_rotation;
        const Quat  ref_q { rq.w(), rq.x(), rq.y(), rq.z() };

        std::array<double, 3> trans = ref_t;
        std::array<double, 3> scale = ref_s;
        Quat                  rot   = ref_q;

        // Layers apply in stack order onto the running pose, which starts at the
        // reference; nothing is normalised across layers (0x1401FDF90). A bone the
        // clip does not hold, or whose track is flagged off, keeps the value below.
        const auto sample = [&](usize k) {
            const auto& layer = state.m_layers[k];
            if (layer.anim == nullptr || ! layer.anim_layer.visible) return;
            const double weight = layer.blend;
            if (weight == 0.0) return;
            const auto& source = *played[k];
            if (i >= source.bone_tracks.size()) return;
            BlendTrack(source.bone_tracks[i], layer.interp_info.frame_a + offsets[k],
                       layer.interp_info.frame_b + offsets[k], layer.interp_info.t, weight,
                       layer.anim_layer.additive, ref_t, ref_s, ref_q, trans, scale, rot);
        };
        for (usize k = 0; k < layer_count; k++) {
            sample(k);
            const auto& lock = locks[k];
            if (! lock.active || lock.bone != i) continue;
            // sub_140225900: the locked axes go back to where the clip starts, by the layer's
            // weight; the yaw so far is taken out of the root's turn, and out of its
            // translation when only y may be locked.
            const uint32_t axes[3] = { kRootX, kRootY, kRootZ };
            for (usize c = 0; c < 3; c++) {
                if ((lock.flags & axes[c]) != 0) trans[c] += (lock.start_t[c] - lock.sample_t[c]) * lock.weight;
            }
            if ((lock.flags & kRootYaw) != 0) rot = Mul(lock.turn_q, rot);
            if ((lock.flags & (kRootX | kRootZ | kRootYaw)) == kRootYaw) trans = Apply3(lock.turn, trans);
        }
        rot = Normalized(rot);

        const bool root = bone.anim_parent == NO_PARENT;
        bool       has_parent = ! root;
        if (has_parent && bone.anim_parent >= i) {
            if (! reported_parent) {
                LOG_ERROR("puppet bone %zu names animation parent %u that is not before it; "
                          "treated as a root", i, bone.anim_parent);
                reported_parent = true;
            }
            has_parent = false;
        }
        if (! has_parent && world_anchored_bones) {
            for (usize c = 0; c < 3; c++) trans[c] += bone.vertex_centroid_offset(static_cast<int>(c));
        }
        Mat4 local       = Compose(trans, rot, scale);
        world[i]         = has_parent ? Mul(world[bone.anim_parent], local) : local;
        if (state.m_ik != nullptr && next_bone_link < state.m_ik->plan->bone_links.size() &&
            state.m_ik->plan->bone_links[next_bone_link].bone == i) {
            // Native ordinary rules change the world pose before simulation and
            // descendants, while the authored local pose remains the animation's.
            if (state.m_ik->plan->chains.empty()) {
                // Ordinary-only puppets need current poses only for source bones
                // already visited. Later sources keep this instance's last pose.
                // Do not copy every bone a second time just for sparse rules.
                const auto& links = state.m_ik->plan->bone_links;
                for (usize at=next_bone_link;at<links.size() && links[at].bone==i;++at)
                    if (links[at].source_bone<i)
                        ToAffine(world[links[at].source_bone],state.m_model_bones[links[at].source_bone]);
            }
            ToAffine(world[i],state.m_model_bones[i]);
            ApplyPuppetBoneLinks(*state.m_ik,static_cast<uint32_t>(i),next_bone_link,state.m_model_bones);
            world[i] = FromAffine(state.m_model_bones[i]);
        }
        // The bone's simulation, right after its animated pose and before any bone below it
        // (0x140201377): the step multiplies the model matrix by the bone's offset.
        if (state.m_physics_applies && bone.simulation.simulates() && i < state.m_physics.size()) {
            auto& offset = state.m_physics_offset[i];
            if (state.m_physics_step) {
                const Mat4 current = Mul(Mat4 { state.m_step_world }, world[i]);
                const auto& w      = state.m_step_world;
                const double layer_scale =
                    (std::sqrt(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]) + std::sqrt(w[4] * w[4] + w[5] * w[5] + w[6] * w[6]) +
                     std::sqrt(w[8] * w[8] + w[9] * w[9] + w[10] * w[10])) / 3.0;
                offset = StepBonePhysics(bone.simulation, state.m_physics[i], current.e, state.m_prev_world[i],
                                         layer_scale, state.m_physics_dt);
            }
            world[i] = Mul(world[i], Mat4 { offset });
        }
        if (state.m_ik != nullptr && !state.m_ik->plan->chains.empty()) {
            ToAffine(world[i], state.m_model_bones[i]);
            const int32_t chain = state.m_ik->plan->at_bone.empty() ? -1 : state.m_ik->plan->at_bone[i];
            if (chain >= 0) {
                SolvePuppetIk(*this, *state.m_ik, static_cast<usize>(chain), state.m_model_bones);
                for (const auto bone_index : state.m_ik->plan->chains[static_cast<usize>(chain)].affected) {
                    world[bone_index] = FromAffine(state.m_model_bones[bone_index]);
                }
                local = world[i];
                Mat4 inverse;
                if (has_parent && InvertAffine(world[bone.anim_parent], inverse)) local = Mul(inverse, world[i]);
            }
        }
        if (i < state.m_local_bones.size()) ToAffine(local, state.m_local_bones[i]);
    }
    for (usize i = 0; i < count; i++) {
        if (i < state.m_model_bones.size()) ToAffine(world[i], state.m_model_bones[i]);
        ToAffine(Mul(world[i], FromAffine(bones[i].inv_bind)), out[i]);
    }
}

WPPuppet::Animation::InterpolationInfo WPPuppet::Animation::getInterpolationInfo(double* cur_time) const {
    InterpolationInfo info { 0, 0, 0.0 };
    if (cur_time == nullptr || ! std::isfinite(*cur_time)) return info;
    if (! (frame_time > 0.0) || ! (max_time > 0.0) || length <= 0) return info;

    const double frames = static_cast<double>(length);
    double       c      = *cur_time;
    switch (mode) {
    case PlayMode::Single: {
        if (c < 0.0) c = 0.0;
        if (c >= max_time) {
            *cur_time = max_time;
            info.frame_a = info.frame_b = static_cast<idx>(length);
            return info;
        }
        *cur_time        = c;
        const double u   = c / frame_time;
        const double fl  = std::floor(u);
        if (fl >= frames) {
            info.frame_a = info.frame_b = static_cast<idx>(length);
            return info;
        }
        info.frame_a = static_cast<idx>(fl);
        info.frame_b = info.frame_a + 1;
        info.t       = u - fl;
        return info;
    }
    case PlayMode::Mirror: {
        const double period = max_time * 2.0;
        c                   = std::fmod(c, period);
        if (c < 0.0) c += period;
        if (c >= period) c = 0.0;
        double v = c / frame_time;
        // A time a hair below the period can still divide up to the full 2L frames: that is the
        // wrap point, not a position past it.
        if (v >= frames * 2.0) {
            c = 0.0;
            v = 0.0;
        }
        *cur_time       = c;
        const double fl = std::floor(v);
        const auto at = [&](double k) {
            return static_cast<idx>(k <= frames ? k : frames * 2.0 - k);
        };
        info.frame_a = at(fl);
        info.frame_b = at(fl + 1.0);
        info.t       = v - fl;
        return info;
    }
    case PlayMode::Loop:
    default: {
        c = std::fmod(c, max_time);
        if (c < 0.0) c += max_time;
        if (c >= max_time) c = 0.0;
        *cur_time       = c;
        const double u  = c / frame_time;
        const double fl = std::floor(u);
        info.frame_a    = static_cast<idx>(std::fmod(fl, frames));
        info.frame_b    = info.frame_a + 1;
        info.t          = u - fl;
        return info;
    }
    }
}

void WPPuppetLayer::prepared(std::span<AnimationLayer> layers) {
    if (! m_state || ! m_puppet) return;
    auto& state = *m_state;
    state.m_layers.clear();
    state.m_layers.reserve(layers.size());
    for (const auto& authored : layers) {
        Layer layer { authored, 0.0, nullptr, {} };
        layer.serial = static_cast<i32>(state.m_layers.size());
        if (! std::isfinite(layer.anim_layer.cur_time)) layer.anim_layer.cur_time = 0.0;
        // The first animation in file order with the entry's id.
        for (const auto& anim : m_puppet->anims) {
            if (anim.id == authored.id) {
                layer.anim = &anim;
                break;
            }
        }
        if (layer.anim != nullptr) {
            // sub_1401FCC20 builds authored and script-created layers alike: only a
            // single-shot clip keeps blendout. Scripts can still enable it later.
            if (layer.anim->mode != WPPuppet::PlayMode::Single) layer.anim_layer.blendout = false;
            layer.interp_info = layer.anim->getInterpolationInfo(&layer.anim_layer.cur_time);
        }
        state.m_layers.push_back(std::move(layer));
    }
    state.m_next_serial = static_cast<i32>(state.m_layers.size());
    state.m_finished_layers.clear();
    const usize bones = m_puppet->bones.size();
    if (state.m_final_affines.size() != bones) state.m_final_affines.resize(bones, Affine3f::Identity());
    if (state.m_model_bones.size() != bones) state.m_model_bones.assign(bones, Affine3f::Identity());
    if (state.m_local_bones.size() != bones) state.m_local_bones.assign(bones, Affine3f::Identity());
    // WE's model path leaves bone-free models static, even when a material explicitly
    // enables MORPHING. Their MDMP data must not create an animation consumer.
    if (!m_puppet->morph_meshes.empty() && state.m_morph == nullptr &&
        (state.m_composition != CompositionKind::Model || bones != 0)) {
        const usize count = state.m_composition == CompositionKind::ImagePuppet ? 1 : m_puppet->morph_meshes.size();
        const auto begin = m_puppet->morph_meshes.begin();
        if (std::any_of(begin, begin + count, [](const auto& mesh) { return !mesh.shapes.empty(); })) {
            state.m_morph = std::make_shared<PuppetMorphState>();
            state.m_morph->meshes.resize(count);
            for (usize i = 0; i < count; ++i) {
                auto& target = state.m_morph->meshes[i];
                const auto& info = m_puppet->morph_meshes[i];
                target.weights.resize(info.shapes.size());
                target.active.resize(info.shapes.size());
                target.writes.reserve(info.shapes.size());
                if (info.modifiers && state.m_composition == CompositionKind::ImagePuppet && !info.shapes.empty()) {
                    std::array<float, 176> transforms {};
                    for (usize j = 0; j < 11; ++j) for (usize lane : {0u, 5u, 10u, 15u}) transforms[j * 16 + lane] = 1;
                    target.uniforms.transforms = ShaderValue(transforms);
                    target.uniforms.rules = ShaderValue(std::array<float, 33> {});
                }
            }
        }
    }
    if (state.m_composition == CompositionKind::ImagePuppet && m_puppet->ik_plan != nullptr) {
        if (state.m_ik == nullptr || state.m_ik->plan != m_puppet->ik_plan) {
            state.m_ik = std::make_shared<PuppetIkState>(m_puppet->ik_plan);
            if (!m_puppet->ik_plan->reference.empty())
                state.m_model_bones = m_puppet->ik_plan->reference;
        }
    } else {
        state.m_ik.reset();
    }
    // Simulation state only for a puppet that simulates; a puppet without costs nothing.
    if (m_puppet->has_simulation && state.m_physics.size() != bones) {
        constexpr std::array<double, 16> identity { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        state.m_physics.assign(bones, BonePhysicsState {});
        state.m_physics_offset.assign(bones, identity);
        state.m_prev_world.assign(bones, identity);
        state.m_physics_primed  = false;
        state.m_physics_applies = false;
    }
    updateWeights();
    state.m_pose_valid = false;
}

// we_AnimLayerEffectiveBlend 0x14026C8B0: the blend, faded in over the first and
// out over the last min(clip / 2, blendtime) seconds. A clip that fades over
// less than a float epsilon does not fade. For a mirrored clip the time and the
// length are those of one pass, as Wallpaper Engine's clock bounces inside it.
void WPPuppetLayer::updateWeights() noexcept {
    if (! m_state) return;
    for (auto& layer : m_state->m_layers) {
        auto& authored = layer.anim_layer;
        layer.blend    = 0.0;
        if (layer.anim == nullptr || ! authored.visible) continue;
        bool clear  = false;
        layer.blend = EffectiveBlend(authored, *layer.anim, authored.cur_time, &clear);
        // A looping or mirrored clip fades in once (flag 4 cleared).
        if (clear) authored.blendin = false;
    }
}

void WPPuppetLayer::setRootMotion(bool on) noexcept {
    if (m_state) m_state->m_root_motion = on;
}

bool WPPuppetLayer::rootMotion() const noexcept { return m_state && m_state->m_root_motion; }

std::vector<WPPuppetLayer::RootMotionStep> WPPuppetLayer::takeRootMotion() noexcept {
    if (! m_state) return {};
    std::vector<RootMotionStep> steps;
    steps.swap(m_state->m_root_motion_steps);
    return steps;
}

std::span<const float> WPPuppetLayer::boneAlpha() const noexcept {
    if (! m_state || ! m_puppet || ! m_puppet->bone_alpha) return {};
    return m_state->m_bone_alpha;
}

void WPPuppetLayer::textureChannelWeights(double time, std::span<float> out) noexcept {
    std::fill(out.begin(), out.end(), 0.0f);
    if (! m_puppet || ! m_state) return;
    genFrame(time);
    const auto& state = *m_state;
    double      total = 0.0;
    for (const auto& layer : state.m_layers) {
        if (layer.anim != nullptr && layer.anim_layer.visible && layer.blend > 0.0) total += layer.blend;
    }
    if (! (total > 0.0) || ! std::isfinite(total)) return;
    for (const auto& layer : state.m_layers) {
        if (layer.anim == nullptr || ! layer.anim_layer.visible || ! (layer.blend > 0.0)) continue;
        const double share    = layer.blend / total;
        const auto&  channels = layer.anim->texture_channels;
        const auto&  frames   = layer.interp_info;
        for (usize channel = 0; channel < std::min(out.size(), channels.size()); channel++) {
            const auto& weights = channels[channel];
            if (weights.empty()) continue;
            const auto at = [&weights](idx frame) {
                const usize clamped = std::min(static_cast<usize>(std::max<idx>(frame, 0)), weights.size() - 1);
                return static_cast<double>(weights[clamped]);
            };
            const double sample = at(frames.frame_a) + (at(frames.frame_b) - at(frames.frame_a)) * frames.t;
            if (std::isfinite(sample)) out[channel] += static_cast<float>(share * sample);
        }
    }
}

bool WPPuppetLayer::simulates() const noexcept {
    return m_puppet && m_state &&
           (m_puppet->has_simulation || (m_state->m_ik != nullptr && m_state->m_ik->plan->has_rope));
}

bool WPPuppetLayer::usesSceneForces() const noexcept {
    return m_state && m_state->m_ik && m_state->m_ik->plan->has_rope;
}

void WPPuppetLayer::setSceneForces(std::shared_ptr<const SceneForceState> forces) noexcept {
    if (usesSceneForces()) m_state->m_ik->forces = std::move(forces);
}

void WPPuppetLayer::setLayerWorld(const linalg::Matrix4d& world) noexcept {
    if (! simulates()) return;
    std::array<double, 16> e {};
    for (usize i = 0; i < 16; i++) e[i] = world.data()[i];
    if (std::all_of(e.begin(), e.end(), [](double v) { return std::isfinite(v); })) m_state->m_layer_world = e;
}

bool WPPuppetLayer::applyBoneImpulse(usize bone, const linalg::Vector3d& linear,
                                     const linalg::Vector3d& angular_degrees) noexcept {
    if (! simulates() || bone >= m_state->m_physics.size() || ! m_puppet->bones[bone].simulation.simulates()) {
        return false;
    }
    if (! linear.allFinite() || ! angular_degrees.allFinite()) return false;
    ApplyBonePhysicsImpulse(m_state->m_physics[bone], { linear.x(), linear.y(), linear.z() },
                            { angular_degrees.x(), angular_degrees.y(), angular_degrees.z() });
    return true;
}

bool WPPuppetLayer::resetBoneSimulation(usize bone) noexcept {
    if (! simulates() || bone >= m_state->m_physics.size() || ! m_puppet->bones[bone].simulation.simulates()) {
        return false;
    }
    m_state->m_physics[bone] = BonePhysicsState {};
    return true;
}

std::span<const linalg::Affine3f> WPPuppetLayer::genFrame(double time) noexcept {
    if (! m_puppet || ! m_state) return {};
    auto& state = *m_state;
    const auto time_bits = std::bit_cast<uint64_t>(time);
    if (state.m_pose_valid && std::isfinite(time) && state.m_pose_time_bits == time_bits) {
        return state.m_final_affines;
    }

    state.m_pose_valid = false;
    // Script bone writes last until the clock moves (B-D8: the composer rebuilds every bone each
    // frame and the scripts run after it); a recompute at the same time keeps them.
    if (state.m_pose_time_bits != time_bits) {
        state.m_script_writes.clear();
        if (state.m_morph) for (auto& mesh : state.m_morph->meshes) mesh.writes.clear();
    }
    if (m_puppet->has_simulation && state.m_physics.size() == m_puppet->bones.size()) {
        // A step per clock move (B-D2): last step's final bones (after the simulation, IK and
        // script writes) are where it starts from, Wallpaper Engine's +840. A recompute at the
        // same time puts the same offsets on the new pose. The first evaluation only records.
        const bool moved = state.m_pose_time_bits != time_bits || ! state.m_physics_primed;
        state.m_physics_step = false;
        if (moved) {
            if (state.m_physics_primed && std::isfinite(time)) {
                const Mat4 world { state.m_step_world };
                for (usize b = 0; b < state.m_prev_world.size() && b < state.m_model_bones.size(); b++) {
                    state.m_prev_world[b] = Mul(world, FromAffine(state.m_model_bones[b])).e;
                }
                // The scene step Wallpaper Engine hands the composer is at most 0.25 s (E-D9).
                state.m_physics_dt      = std::clamp(time - state.m_physics_time, 0.0, 0.25);
                state.m_physics_step    = true;
                state.m_physics_applies = true;
            }
            state.m_step_world   = state.m_layer_world;
            state.m_physics_time = time;
        }
    }
    if (state.m_ik != nullptr) BeginPuppetIkFrame(*state.m_ik, time, state.m_layer_world);
    updateInterpolation(time);
    m_puppet->evaluatePose(*this, state.m_final_affines);
    state.m_physics_primed = m_puppet->has_simulation;
    for (const auto& write : state.m_script_writes) applyBoneWrite(write);
    if (state.m_morph) for (auto& mesh : state.m_morph->meshes) {
        for (const auto& [shape, weight] : mesh.writes) {
            mesh.weights[shape] = weight;
            mesh.active[shape] = std::abs(weight) >= std::numeric_limits<float>::epsilon();
        }
    }
    state.m_pose_time_bits = time_bits;
    state.m_pose_valid =
        std::isfinite(time) && std::isfinite(state.m_last_elapsed) &&
        std::all_of(state.m_layers.begin(), state.m_layers.end(), [](const Layer& layer) {
            const auto& authored = layer.anim_layer;
            return std::isfinite(authored.rate) && std::isfinite(authored.blend) &&
                   std::isfinite(authored.cur_time) && std::isfinite(layer.blend) &&
                   std::isfinite(layer.interp_info.t);
        });
    return state.m_final_affines;
}

namespace
{
// A later write of the same kind to the same bone replaces the earlier one, so a script that
// writes every frame of a paused clock keeps one record a bone.
template <typename Writes, typename Write>
void RecordBoneWrite(Writes& writes, const Write& write) {
    std::erase_if(writes, [&](const Write& w) { return w.bone == write.bone && w.local == write.local; });
    writes.push_back(write);
}
} // namespace

usize WPPuppetLayer::boneCount() const noexcept { return m_puppet ? m_puppet->bones.size() : 0; }

i32 WPPuppetLayer::boneIndex(std::string_view name) const noexcept {
    if (! m_puppet || name.empty()) return -1;
    for (usize i = 0; i < m_puppet->bones.size(); i++) {
        if (m_puppet->bones[i].name == name) return static_cast<i32>(i);
    }
    return -1;
}

i32 WPPuppetLayer::boneParent(i32 bone) const noexcept {
    if (! m_puppet || bone < 0 || static_cast<usize>(bone) >= m_puppet->bones.size()) return -1;
    const uint32_t parent = m_puppet->bones[static_cast<usize>(bone)].file_parent;
    return parent == WPPuppet::NO_PARENT ? -1 : static_cast<i32>(parent);
}

i32 WPPuppetLayer::attachmentIndex(std::string_view name) const noexcept {
    if (!m_puppet) return -1;
    for (usize i=0;i<m_puppet->attachments.size();++i)
        if (m_puppet->attachments[i].name==name) return static_cast<i32>(i);
    return -1;
}

std::optional<WPPuppetLayer::AttachmentBinding> WPPuppetLayer::attachmentBinding(i32 index) const {
    if (!m_puppet || index<0 || static_cast<usize>(index)>=m_puppet->attachments.size()) return std::nullopt;
    const auto& attachment=m_puppet->attachments[static_cast<usize>(index)];
    if (attachment.bone_index>=m_puppet->bones.size()) return std::nullopt;
    return AttachmentBinding{attachment.bone_index,
        m_puppet->bones[attachment.bone_index].world_bind*attachment.local_xform};
}

std::optional<linalg::Affine3f> WPPuppetLayer::attachmentTransform(i32 index) const {
    if (!m_puppet || !m_state || index<0 || static_cast<usize>(index)>=m_puppet->attachments.size())
        return std::nullopt;
    const auto& attachment=m_puppet->attachments[static_cast<usize>(index)];
    if (attachment.bone_index>=m_state->m_model_bones.size()) return std::nullopt;
    return linalg::Affine3f(m_state->m_model_bones[attachment.bone_index]*attachment.local_xform);
}

std::span<const linalg::Affine3f> WPPuppetLayer::modelBones() const noexcept {
    if (! m_state) return {};
    return m_state->m_model_bones;
}

std::optional<std::string> WPPuppetLayer::hitBoxName(const Matrix4d& layer_world,
                                                   const Vector3d& ray_origin,
                                                   const Vector3d& ray_direction) const {
    if (! m_puppet || ! m_state || ! m_state->m_clock_started ||
        m_state->m_composition != CompositionKind::ImagePuppet ||
        ! layer_world.allFinite() || ! ray_origin.allFinite() ||
        ! ray_direction.allFinite() || ray_direction.isZero()) return std::nullopt;
    const auto posed = modelBones();
    for (auto at = m_puppet->hit_box_order.rbegin(); at != m_puppet->hit_box_order.rend(); ++at) {
        const auto index = *at;
        if (index >= posed.size() || index >= m_puppet->bones.size()) continue;
        const auto& bone = m_puppet->bones[index];
        if (! bone.has_file_skin_pivot || ! bone.file_skin_pivot.allFinite()) continue;
        const Matrix4d world = layer_world * posed[index].matrix().cast<double>() *
                               bone.file_skin_mat.cast<double>();
        if (! world.allFinite() || world.determinant() == 0.0) continue;
        const Matrix4d inverse = world.inverse();
        if (! inverse.allFinite()) continue;
        const Vector3d origin = (inverse * Vector4d(ray_origin.x(),ray_origin.y(),ray_origin.z(),1)).head<3>();
        const Vector3d direction =
            (inverse * Vector4d(ray_direction.x(),ray_direction.y(),ray_direction.z(),0)).head<3>();
        const Vector3d extent = bone.file_skin_pivot.cast<double>().cwiseAbs();
        double near = -std::numeric_limits<double>::infinity();
        double far = std::numeric_limits<double>::infinity();
        bool hit = true;
        for (int axis=0;axis<3;++axis) {
            if (direction[axis] == 0.0) {
                if (std::abs(origin[axis]) > extent[axis]) { hit=false; break; }
                continue;
            }
            double first = (-extent[axis]-origin[axis])/direction[axis];
            double last = (extent[axis]-origin[axis])/direction[axis];
            if (first > last) std::swap(first,last);
            near = std::max(near,first);
            far = std::min(far,last);
            if (far < near) { hit=false; break; }
        }
        if (hit) return bone.name.empty() ? std::to_string(index) : bone.name;
    }
    return std::nullopt;
}

std::span<const linalg::Affine3f> WPPuppetLayer::lastFrame() const noexcept {
    return m_state && m_state->m_clock_started ? std::span<const linalg::Affine3f>(m_state->m_final_affines)
                   : std::span<const linalg::Affine3f> {};
}

std::span<const linalg::Affine3f> WPPuppetLayer::localBones() const noexcept {
    if (! m_state) return {};
    return m_state->m_local_bones;
}

bool WPPuppetLayer::setModelBone(usize bone, const linalg::Affine3f& model) noexcept {
    if (! m_state || ! m_puppet || bone >= m_puppet->bones.size() || bone >= m_state->m_model_bones.size())
        return false;
    State::ScriptWrite write { false, bone, model };
    applyBoneWrite(write);
    RecordBoneWrite(m_state->m_script_writes, write);
    return true;
}

bool WPPuppetLayer::setLocalBone(usize bone, const linalg::Affine3f& local) noexcept {
    if (! m_state || ! m_puppet || bone >= m_puppet->bones.size() || bone >= m_state->m_local_bones.size())
        return false;
    State::ScriptWrite write { true, bone, local };
    applyBoneWrite(write);
    RecordBoneWrite(m_state->m_script_writes, write);
    return true;
}

void WPPuppetLayer::applyBoneWrite(const State::ScriptWrite& write) noexcept {
    auto&       state = *m_state;
    if (state.m_morph) for (auto& mesh : state.m_morph->meshes) mesh.dirty = true;
    const auto& bones = m_puppet->bones;
    const usize count = std::min({ bones.size(), state.m_model_bones.size(), state.m_local_bones.size(),
                                   state.m_final_affines.size() });
    if (write.bone >= count) return;
    if (! write.local) {
        // 0x14020F350: model = the written matrix, palette = model * bind inverse; that bone only.
        state.m_model_bones[write.bone] = write.matrix;
        state.m_final_affines[write.bone] = write.matrix * bones[write.bone].inv_bind;
        return;
    }
    // sub_14020DB40: the bone and every bone below it, in index order, from their locals.
    state.m_local_bones[write.bone] = write.matrix;
    thread_local std::vector<bool> below;
    below.assign(count, false);
    for (usize j = write.bone; j < count; j++) {
        const uint32_t parent    = bones[j].anim_parent;
        const bool     has_parent = parent != WPPuppet::NO_PARENT && parent < j;
        below[j]                 = j == write.bone || (has_parent && below[parent]);
        if (! below[j]) continue;
        state.m_model_bones[j] =
            has_parent ? state.m_model_bones[parent] * state.m_local_bones[j] : state.m_local_bones[j];
        state.m_final_affines[j] = state.m_model_bones[j] * bones[j].inv_bind;
    }
}

void WPPuppetLayer::invalidatePose() noexcept {
    if (m_state) m_state->m_pose_valid = false;
}

void WPPuppetLayer::updateInterpolation(double time) noexcept {
    if (! m_state) return;
    auto& state = *m_state;

    // The weights the layers have before their clocks step: the root-motion extraction reads
    // the layers above it at that point (0x14021cc7d runs before their own steps).
    for (auto& layer : state.m_layers) {
        layer.pre_step_blend = layer.anim != nullptr && layer.anim_layer.visible
                                   ? EffectiveBlend(layer.anim_layer, *layer.anim, layer.anim_layer.cur_time, nullptr)
                                   : 0.0;
        layer.cycle_prev = layer.anim_layer.cur_time;
    }
    if (std::isfinite(time)) {
        if (! state.m_clock_started) {
            // The first evaluation only learns where the clock is.
            state.m_clock_started = true;
            state.m_last_elapsed  = time;
        } else if (time > state.m_last_elapsed) {
            const double elapsed = time - state.m_last_elapsed;
            state.m_last_elapsed = time;
            for (auto& layer : state.m_layers) {
                if (! layer.anim_layer.playing) continue;
                layer.anim_layer.cur_time += elapsed * layer.anim_layer.rate;
                if (! std::isfinite(layer.anim_layer.cur_time)) layer.anim_layer.cur_time = 0.0;
            }
        }
    }

    // Step 1: record, for every layer, which frames its current time maps to.
    for (auto& layer : state.m_layers) {
        double& cur = layer.anim_layer.cur_time;
        if (! std::isfinite(cur)) cur = 0.0;
        if (layer.anim != nullptr) layer.interp_info = layer.anim->getInterpolationInfo(&cur);
    }
    // The weights follow the clock they fade by.
    updateWeights();

    // Step 2: notify every cycle end (0x1401FDF90). Ordinary loops and mirrors
    // keep running; single-shot and playSingleAnimation layers stop here.
    for (auto& layer : state.m_layers) {
        if (layer.pending_destroy) continue;
        const bool finished = HasReachedEnd(layer.anim_layer, layer.anim);
        const bool ended = finished ||
                           (layer.anim_layer.playing && layer.anim != nullptr &&
                            EndedACycle(*layer.anim, layer.cycle_prev, layer.anim_layer.cur_time));
        if (! ended) continue;
        if (finished || layer.destroy_on_end) layer.anim_layer.playing = false;
        if (layer.destroy_on_end) layer.pending_destroy = true;
        PostFinishNotice(state.m_finished_layers, layer.serial);
    }
}

std::vector<WPPuppetLayer::FinishedLayer> WPPuppetLayer::takeFinishedLayers() noexcept {
    if (! m_state) return {};
    std::vector<FinishedLayer> finished;
    finished.reserve(m_state->m_finished_layers.size());
    for (const i32 serial : m_state->m_finished_layers) {
        const auto& layers = m_state->m_layers;
        const auto  found  = std::find_if(layers.begin(), layers.end(),
                                          [serial](const Layer& layer) { return layer.serial == serial; });
        finished.push_back(FinishedLayer { serial, found != layers.end() && found->pending_destroy });
    }
    m_state->m_finished_layers.clear();
    return finished;
}

void WPPuppetLayer::removeEndedLayers() noexcept {
    if (! m_state) return;
    std::erase_if(m_state->m_layers, [](const Layer& layer) { return layer.pending_destroy; });
    // 0x1401FDF90 deletes after composing the pose and calling listeners. Keep that
    // frame's palette for the draw; the next clock step composes the smaller stack.
}

i32 WPPuppetLayer::layerSerial(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer != nullptr ? layer->serial : -1;
}

std::optional<i32> WPPuppetLayer::animationIdNamed(std::string_view name) const noexcept {
    if (! m_puppet) return std::nullopt;
    for (const auto& anim : m_puppet->anims) {
        if (anim.name == name) return anim.id;
    }
    return std::nullopt;
}

i32 WPPuppetLayer::createLayer(AnimationLayer authored, LayerPlacement placement, bool destroy_on_end) noexcept {
    if (! m_state || ! m_puppet) return -1;
    auto&                      state = *m_state;
    const WPPuppet::Animation* anim  = nullptr;
    for (const auto& candidate : m_puppet->anims) {
        if (candidate.id == authored.id) {
            anim = &candidate;
            break;
        }
    }
    if (anim == nullptr) return -1;
    Layer layer { std::move(authored), 0.0, anim, {} };
    if (! std::isfinite(layer.anim_layer.cur_time)) layer.anim_layer.cur_time = 0.0;
    // sub_1401FCC20: `if ((layer+260 & 2) == 0) layer+208 &= ~8` -- only a clip that plays
    // once fades out.
    if (anim->mode != WPPuppet::PlayMode::Single) layer.anim_layer.blendout = false;
    layer.interp_info    = anim->getInterpolationInfo(&layer.anim_layer.cur_time);
    layer.serial         = state.m_next_serial++;
    layer.destroy_on_end = destroy_on_end;

    const usize size = state.m_layers.size();
    usize       at   = size;
    if (placement.autosort) {
        // Below the additive layers on top of the stack.
        while (at > 0 && state.m_layers[at - 1].anim_layer.additive) --at;
    } else if (placement.index.has_value() && size > 0) {
        // min((unsigned)index, size - 1): a negative index wraps to a huge one.
        const double index = *placement.index;
        at = ! (index >= 0.0) || index >= static_cast<double>(size - 1) ? size - 1
                                                                         : static_cast<usize>(index);
    }
    state.m_layers.insert(state.m_layers.begin() + static_cast<std::ptrdiff_t>(at), std::move(layer));

    const usize bones = m_puppet->bones.size();
    if (state.m_final_affines.size() != bones) state.m_final_affines.resize(bones, Affine3f::Identity());
    if (state.m_model_bones.size() != bones) state.m_model_bones.assign(bones, Affine3f::Identity());
    if (state.m_local_bones.size() != bones) state.m_local_bones.assign(bones, Affine3f::Identity());
    updateWeights();
    invalidatePose();
    return static_cast<i32>(at);
}

bool WPPuppetLayer::destroyLayer(i32 index) noexcept {
    if (layerAt(index) == nullptr) return false;
    auto& state = *m_state;
    std::erase(state.m_finished_layers, state.m_layers[static_cast<usize>(index)].serial);
    state.m_layers.erase(state.m_layers.begin() + index);
    invalidatePose();
    return true;
}

bool WPPuppetLayer::destroyLayersNamed(std::string_view name) noexcept {
    if (! m_state) return false;
    bool gone = false;
    for (i32 i = 0; i < static_cast<i32>(m_state->m_layers.size());) {
        if (m_state->m_layers[static_cast<usize>(i)].anim_layer.name == name) {
            destroyLayer(i);
            gone = true;
        } else {
            ++i;
        }
    }
    return gone;
}

WPPuppetLayer::Layer* WPPuppetLayer::layerAt(i32 index) noexcept {
    if (! m_state || index < 0 || static_cast<usize>(index) >= m_state->m_layers.size()) {
        return nullptr;
    }
    return &m_state->m_layers[static_cast<usize>(index)];
}

const WPPuppetLayer::Layer* WPPuppetLayer::layerAt(i32 index) const noexcept {
    if (! m_state || index < 0 || static_cast<usize>(index) >= m_state->m_layers.size()) {
        return nullptr;
    }
    return &m_state->m_layers[static_cast<usize>(index)];
}

i32 WPPuppetLayer::findLayer(std::string_view name, bool by_serial) const noexcept {
    if (! m_state) return -1;
    const auto& layers = m_state->m_layers;
    // A script object names its layer by serial: "#<serial>".
    if (by_serial) {
        if (name.size() <= 1 || name.front() != '#') return -1;
        i32 serial = 0;
        for (const char ch : name.substr(1)) {
            if (ch < '0' || ch > '9' || serial > 100000000) return -1;
            serial = serial * 10 + (ch - '0');
        }
        for (usize i = 0; i < layers.size(); i++) {
            if (layers[i].serial == serial) return static_cast<i32>(i);
        }
        return -1;
    }
    for (usize i = 0; i < layers.size(); i++) {
        if (layers[i].anim_layer.name == name) return static_cast<i32>(i);
    }
    // SceneScript also accepts the stack index.
    i32 index = 0;
    for (const char ch : name) {
        if (ch < '0' || ch > '9') return -1;
        index = index * 10 + (ch - '0');
        if (index > 4096) return -1;
    }
    if (name.empty() || static_cast<usize>(index) >= layers.size()) return -1;
    return index;
}

usize WPPuppetLayer::layerCount() const noexcept {
    return m_state ? m_state->m_layers.size() : 0;
}

std::string WPPuppetLayer::layerName(i32 index) const {
    const auto* layer = layerAt(index);
    return layer != nullptr ? layer->anim_layer.name : std::string {};
}

bool WPPuppetLayer::play(i32 index) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    invalidatePose();
    auto& alayer = layer->anim_layer;
    if (! alayer.playing && layer->anim != nullptr &&
        layer->anim->mode == WPPuppet::PlayMode::Single &&
        alayer.cur_time >= layer->anim->max_time) {
        alayer.cur_time = 0.0;
    }
    alayer.playing = true;
    return true;
}

bool WPPuppetLayer::pause(i32 index) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    invalidatePose();
    layer->anim_layer.playing = false;
    return true;
}

bool WPPuppetLayer::stop(i32 index) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    invalidatePose();
    layer->anim_layer.playing  = false;
    layer->anim_layer.cur_time = 0.0;
    if (layer->anim != nullptr) {
        layer->interp_info = layer->anim->getInterpolationInfo(&layer->anim_layer.cur_time);
    }
    return true;
}

bool WPPuppetLayer::isPlaying(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer != nullptr && layer->anim_layer.playing;
}

bool WPPuppetLayer::setFrame(i32 index, double frame) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr || layer->anim == nullptr || ! std::isfinite(frame)) return false;
    invalidatePose();
    const double frames = static_cast<double>(layer->anim->length);
    if (frame < 0.0) frame = 0.0;
    if (frame > frames) frame = frames;
    layer->anim_layer.cur_time = frame * layer->anim->frame_time;
    layer->interp_info = layer->anim->getInterpolationInfo(&layer->anim_layer.cur_time);
    return true;
}

double WPPuppetLayer::frame(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    if (layer == nullptr || layer->anim == nullptr || layer->anim->frame_time <= 0.0) return 0.0;
    return layer->anim_layer.cur_time / layer->anim->frame_time;
}

double WPPuppetLayer::frameCount(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    if (layer == nullptr || layer->anim == nullptr) return 0.0;
    return static_cast<double>(layer->anim->length);
}

double WPPuppetLayer::fps(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    if (layer == nullptr || layer->anim == nullptr) return 0.0;
    return layer->anim->fps;
}

bool WPPuppetLayer::setRate(i32 index, double rate) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr || ! std::isfinite(rate)) return false;
    invalidatePose();
    layer->anim_layer.rate = rate;
    return true;
}

double WPPuppetLayer::rate(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer == nullptr ? 0.0 : layer->anim_layer.rate;
}

bool WPPuppetLayer::setBlend(i32 index, double blend) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr || ! std::isfinite(blend)) return false;
    if (layer->anim_layer.blend == blend) return true;
    invalidatePose();
    layer->anim_layer.blend = blend;
    return true;
}

double WPPuppetLayer::blend(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer == nullptr ? 0.0 : layer->anim_layer.blend;
}

bool WPPuppetLayer::setVisible(i32 index, bool visible) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    if (layer->anim_layer.visible == visible) return true;
    invalidatePose();
    layer->anim_layer.visible = visible;
    return true;
}

bool WPPuppetLayer::visible(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer != nullptr && layer->anim_layer.visible;
}

bool WPPuppetLayer::setAdditive(i32 index, bool additive) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    if (layer->anim_layer.additive == additive) return true;
    invalidatePose();
    layer->anim_layer.additive = additive;
    return true;
}

bool WPPuppetLayer::additive(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer != nullptr && layer->anim_layer.additive;
}

bool WPPuppetLayer::setBlendIn(i32 index, bool blendin) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    if (layer->anim_layer.blendin == blendin) return true;
    invalidatePose();
    layer->anim_layer.blendin = blendin;
    return true;
}

bool WPPuppetLayer::blendIn(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer != nullptr && layer->anim_layer.blendin;
}

bool WPPuppetLayer::setBlendOut(i32 index, bool blendout) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr) return false;
    if (layer->anim_layer.blendout == blendout) return true;
    invalidatePose();
    layer->anim_layer.blendout = blendout;
    return true;
}

bool WPPuppetLayer::blendOut(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer != nullptr && layer->anim_layer.blendout;
}

bool WPPuppetLayer::setBlendTime(i32 index, double seconds) noexcept {
    auto* layer = layerAt(index);
    if (layer == nullptr || ! std::isfinite(seconds) || seconds < 0.0) return false;
    if (layer->anim_layer.blendtime == seconds) return true;
    invalidatePose();
    layer->anim_layer.blendtime = seconds;
    return true;
}

double WPPuppetLayer::blendTime(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer == nullptr ? 0.0 : layer->anim_layer.blendtime;
}

WPPuppetLayer::WPPuppetLayer(std::shared_ptr<WPPuppet> pup, CompositionKind composition)
    : m_state(pup ? std::make_shared<State>() : nullptr), m_puppet(std::move(pup)) {
    if (m_state) {
        m_state->m_composition = composition;
        // An Affine3f is not initialised: a bone read before the first pose skins nothing.
        m_state->m_final_affines.resize(m_puppet->bones.size(), Affine3f::Identity());
        m_state->m_model_bones.assign(m_puppet->bones.size(), Affine3f::Identity());
        m_state->m_local_bones.assign(m_puppet->bones.size(), Affine3f::Identity());
    }
}
WPPuppetLayer::WPPuppetLayer()  = default;
WPPuppetLayer::~WPPuppetLayer() = default;
