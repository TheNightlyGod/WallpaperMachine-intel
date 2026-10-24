// Clean-room implementation from the WallpaperMachine spec p5-models-puppets.md; written without access to the original source.
#include "WPPuppet.hpp"

#include <algorithm>
#include <array>
#include <bit>
#include <cmath>

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

// Interpolation along the shortest arc between two unit quaternions.
Quat Slerp(const Quat& a, Quat b, double t) {
    double d = Dot(a, b);
    if (d < 0.0) {
        b = Neg(b);
        d = -d;
    }
    double ka, kb;
    if (d > 0.9995) {
        ka = 1.0 - t;
        kb = t;
    } else {
        const double theta = std::acos(std::min(d, 1.0));
        const double s     = std::sin(theta);
        ka                 = std::sin((1.0 - t) * theta) / s;
        kb                 = std::sin(t * theta) / s;
    }
    return Normalized({ ka * a.w + kb * b.w, ka * a.x + kb * b.x, ka * a.y + kb * b.y,
                        ka * a.z + kb * b.z });
}

// The rotation `d` turned `weight` of the way from "no turn": weights outside
// 0..1 extrapolate along the same axis.
Quat Fraction(Quat d, double weight) {
    if (d.w < 0.0) d = Neg(d);
    const double s = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    if (s < 1e-12) return {};
    const double angle = 2.0 * std::atan2(s, d.w);
    const double half  = 0.5 * angle * weight;
    const double k     = std::sin(half) / s;
    return { std::cos(half), d.x * k, d.y * k, d.z * k };
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

// Appends a notice for the layer at `stack_index`; a full queue drops it.
void PostFinishNotice(std::vector<i32>& queue, usize stack_index) {
    if (queue.size() >= kFinishQueueCapacity) return;
    queue.push_back(static_cast<i32>(stack_index));
}

// True when `layer` is a running single-shot animation whose clock has
// reached or passed its duration.
bool HasReachedEnd(const WPPuppetLayer::AnimationLayer& layer, const WPPuppet::Animation* anim) {
    if (anim == nullptr || anim->mode != WPPuppet::PlayMode::Single) return false;
    if (! layer.playing) return false;
    return anim->max_time > 0.0 && layer.cur_time >= anim->max_time;
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
        for (auto& track : anim.bone_tracks) {
            for (auto& frame : track.frames) {
                const Quat q = FromEuler(frame.angle.x(), frame.angle.y(), frame.angle.z());
                frame.quaternion = Quaterniond(q.w, q.x, q.y, q.z);
            }
        }
    }
}

void WPPuppet::evaluatePose(const WPPuppetLayer& pose_layer,
                            std::span<linalg::Affine3f> out) const noexcept {
    if (! pose_layer.m_state) return;
    const auto&  state = *pose_layer.m_state;
    const usize  count = std::min(bones.size(), out.size());
    thread_local std::vector<Mat4> world;
    world.resize(count);
    bool reported_parent = false;

    for (usize i = 0; i < count; i++) {
        const auto& bone = bones[i];
        const std::array<double, 3> ref_t { bone.reference_position(0), bone.reference_position(1),
                                            bone.reference_position(2) };
        const std::array<double, 3> ref_s { bone.reference_scale(0), bone.reference_scale(1),
                                            bone.reference_scale(2) };
        const auto& rq = bone.reference_rotation;
        const Quat  ref_q { rq.w(), rq.x(), rq.y(), rq.z() };

        std::array<double, 3> trans { state.m_global_blend * ref_t[0], state.m_global_blend * ref_t[1],
                                      state.m_global_blend * ref_t[2] };
        std::array<double, 3> scale { state.m_global_blend * ref_s[0], state.m_global_blend * ref_s[1],
                                      state.m_global_blend * ref_s[2] };
        Quat                  rot = ref_q;

        for (const auto& layer : state.m_layers) {
            if (layer.anim == nullptr || ! layer.anim_layer.visible) continue;
            const bool   additive = layer.anim_layer.additive;
            const double weight   = additive ? layer.anim_layer.blend : layer.blend;
            if (weight == 0.0) continue;

            // The layer's sample for this bone, or the reference itself when it
            // holds nothing usable for it.
            std::array<double, 3> p = ref_t;
            std::array<double, 3> k = ref_s;
            Quat                  sample_q = ref_q;
            if (i < layer.anim->bone_tracks.size()) {
                const auto& frames = layer.anim->bone_tracks[i].frames;
                const idx   ia = layer.interp_info.frame_a, ib = layer.interp_info.frame_b;
                const double t = layer.interp_info.t;
                if (ia >= 0 && ib >= 0 && static_cast<usize>(ia) < frames.size() &&
                    static_cast<usize>(ib) < frames.size() && std::isfinite(t)) {
                    const auto& fa = frames[static_cast<usize>(ia)];
                    const auto& fb = frames[static_cast<usize>(ib)];
                    const Quat  qa { fa.quaternion.w(), fa.quaternion.x(), fa.quaternion.y(),
                                     fa.quaternion.z() };
                    const Quat  qb { fb.quaternion.w(), fb.quaternion.x(), fb.quaternion.y(),
                                     fb.quaternion.z() };
                    bool        finite = Finite(qa) && Finite(qb);
                    std::array<double, 3> pa, pb, ka, kb;
                    for (int c = 0; c < 3; c++) {
                        pa[static_cast<usize>(c)] = fa.position(c);
                        pb[static_cast<usize>(c)] = fb.position(c);
                        ka[static_cast<usize>(c)] = fa.scale(c);
                        kb[static_cast<usize>(c)] = fb.scale(c);
                        finite = finite && std::isfinite(pa[static_cast<usize>(c)]) &&
                                 std::isfinite(pb[static_cast<usize>(c)]) &&
                                 std::isfinite(ka[static_cast<usize>(c)]) &&
                                 std::isfinite(kb[static_cast<usize>(c)]);
                    }
                    if (finite) {
                        for (usize c = 0; c < 3; c++) {
                            p[c] = pa[c] + (pb[c] - pa[c]) * t;
                            k[c] = ka[c] + (kb[c] - ka[c]) * t;
                        }
                        sample_q = Slerp(qa, qb, t);
                    }
                }
            }
            for (usize c = 0; c < 3; c++) {
                if (additive) {
                    trans[c] += weight * (p[c] - ref_t[c]);
                    scale[c] += weight * (k[c] - ref_s[c]);
                } else {
                    trans[c] += weight * p[c];
                    scale[c] += weight * k[c];
                }
            }
            // The turn from the reference to the sample, in the bone's own frame.
            const Quat delta = Normalized(Mul(Conj(ref_q), sample_q));
            rot              = Mul(rot, Fraction(delta, weight));
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
        const Mat4 local = Compose(trans, rot, scale);
        world[i]         = has_parent ? Mul(world[bone.anim_parent], local) : local;
    }
    for (usize i = 0; i < count; i++) {
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
        if (! std::isfinite(layer.anim_layer.cur_time)) layer.anim_layer.cur_time = 0.0;
        // The first animation in file order with the entry's id.
        for (const auto& anim : m_puppet->anims) {
            if (anim.id == authored.id) {
                layer.anim = &anim;
                break;
            }
        }
        if (layer.anim != nullptr) {
            layer.interp_info = layer.anim->getInterpolationInfo(&layer.anim_layer.cur_time);
        }
        state.m_layers.push_back(std::move(layer));
    }
    if (state.m_final_affines.size() != m_puppet->bones.size()) {
        state.m_final_affines.resize(m_puppet->bones.size());
    }
    rebuildBlend();
    state.m_pose_valid = false;
}

void WPPuppetLayer::rebuildBlend() noexcept {
    if (! m_state) return;
    auto& state = *m_state;

    std::vector<usize> absolute;
    double             sum = 0.0;
    for (usize i = 0; i < state.m_layers.size(); i++) {
        auto& layer = state.m_layers[i];
        layer.blend = 0.0;
        if (layer.anim == nullptr || ! layer.anim_layer.visible) continue;
        if (layer.anim_layer.additive) {
            layer.blend = layer.anim_layer.blend;
        } else {
            absolute.push_back(i);
            sum += layer.anim_layer.blend;
        }
    }

    double global = 1.0;
    double total  = 0.0;
    if (sum > 1.0) {
        // Over budget: split it in proportion to the blends; nothing is left
        // for the reference pose.
        global = 0.0;
        for (const usize i : absolute) {
            auto& layer = state.m_layers[i];
            layer.blend = layer.anim_layer.blend / sum;
            total += layer.blend;
        }
    } else {
        // Later layers sit on top, like ordinary alpha compositing.
        double uncovered = 1.0;
        for (auto it = absolute.rbegin(); it != absolute.rend(); ++it) {
            auto& layer = state.m_layers[*it];
            layer.blend = layer.anim_layer.blend * uncovered;
            total += layer.blend;
            uncovered = std::max(0.0, uncovered * (1.0 - layer.anim_layer.blend));
        }
        global = uncovered;
    }
    state.m_global_blend = global;
    state.m_total_blend  = total;
}

std::span<const linalg::Affine3f> WPPuppetLayer::genFrame(double time) noexcept {
    if (! m_puppet || ! m_state) return {};
    auto& state = *m_state;
    const auto time_bits = std::bit_cast<uint64_t>(time);
    if (state.m_pose_valid && std::isfinite(time) && state.m_pose_time_bits == time_bits) {
        return state.m_final_affines;
    }

    state.m_pose_valid = false;
    updateInterpolation(time);
    m_puppet->evaluatePose(*this, state.m_final_affines);
    state.m_pose_time_bits = time_bits;
    state.m_pose_valid =
        std::isfinite(time) && std::isfinite(state.m_last_elapsed) &&
        std::isfinite(state.m_global_blend) && std::isfinite(state.m_total_blend) &&
        std::all_of(state.m_layers.begin(), state.m_layers.end(), [](const Layer& layer) {
            const auto& authored = layer.anim_layer;
            return std::isfinite(authored.rate) && std::isfinite(authored.blend) &&
                   std::isfinite(authored.cur_time) && std::isfinite(layer.blend) &&
                   std::isfinite(layer.interp_info.t);
        });
    return state.m_final_affines;
}

void WPPuppetLayer::invalidatePose() noexcept {
    if (m_state) m_state->m_pose_valid = false;
}

void WPPuppetLayer::updateInterpolation(double time) noexcept {
    if (! m_state) return;
    auto& state = *m_state;

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

    // Step 2: with the frames recorded, find single-shot layers that ran out.
    for (usize i = 0; i < state.m_layers.size(); i++) {
        auto& layer = state.m_layers[i];
        if (! HasReachedEnd(layer.anim_layer, layer.anim)) continue;
        layer.anim_layer.playing = false;
        PostFinishNotice(state.m_finished_layers, i);
    }
}

std::vector<i32> WPPuppetLayer::takeFinishedLayers() noexcept {
    if (! m_state) return {};
    std::vector<i32> finished;
    finished.swap(m_state->m_finished_layers);
    return finished;
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

i32 WPPuppetLayer::findLayer(std::string_view name) const noexcept {
    if (! m_state) return -1;
    const auto& layers = m_state->m_layers;
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
    rebuildBlend();
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
    rebuildBlend();
    return true;
}

bool WPPuppetLayer::visible(i32 index) const noexcept {
    const auto* layer = layerAt(index);
    return layer != nullptr && layer->anim_layer.visible;
}

WPPuppetLayer::WPPuppetLayer(std::shared_ptr<WPPuppet> pup)
    : m_state(pup ? std::make_shared<State>() : nullptr), m_puppet(std::move(pup)) {
    if (m_state) m_state->m_final_affines.resize(m_puppet->bones.size());
}
WPPuppetLayer::WPPuppetLayer()  = default;
WPPuppetLayer::~WPPuppetLayer() = default;
