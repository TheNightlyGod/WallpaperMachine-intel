// Cases that pin the engine's linear-algebra library (Utils/Linalg.hpp) down to the
// last bit. Every case builds its inputs from a seeded generator that does not depend
// on the library, runs one operation of the engine's vocabulary through the library it
// is instantiated with, and flattens the results to doubles. The case lists run against
// the checked-in golden values (linalg_golden.inc), captured once from the library this
// one replaced, so the results that library produced stay pinned.
//
// Nothing here depends on a library but the one passed as the `L` template argument.
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "Utils/Linalg.hpp"

namespace linalg_cases
{

using Out = std::vector<double>;

// --- deterministic inputs ----------------------------------------------------------

// xoshiro256** seeded through splitmix64: the same sequence on every platform, which
// std::mt19937_64 plus the standard distributions would not give.
class Rng {
public:
    explicit Rng(std::uint64_t seed) {
        for (auto& word : s_) {
            seed += 0x9e3779b97f4a7c15ull;
            std::uint64_t z = seed;
            z               = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
            z               = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
            word            = z ^ (z >> 31);
        }
    }
    std::uint64_t next() {
        const std::uint64_t result = rotl(s_[1] * 5, 7) * 9;
        const std::uint64_t t      = s_[1] << 17;
        s_[2] ^= s_[0];
        s_[3] ^= s_[1];
        s_[1] ^= s_[2];
        s_[0] ^= s_[3];
        s_[2] ^= t;
        s_[3] = rotl(s_[3], 45);
        return result;
    }
    // Uniform in [0, 1).
    double uniform() { return static_cast<double>(next() >> 11) * 0x1.0p-53; }
    // Uniform in [-1, 1).
    double sym() { return 2.0 * uniform() - 1.0; }
    int    pick(int n) { return static_cast<int>(next() % static_cast<std::uint64_t>(n)); }
    // A value whose magnitude spans several decades, so sums cancel and round.
    double mixed() {
        const int kind = pick(24);
        if (kind == 0) return 0.0;
        if (kind == 1) return 1.0;
        if (kind == 2) return -1.0;
        if (kind == 3) return 0.5;
        // A decade from 1e-3 to 1e2 times a mantissa in [0.5, 1.5): the range of magnitudes
        // that makes sums cancel, built without any library function whose last bit could
        // differ between C libraries (this stream is part of the golden values).
        static constexpr double decades[] = { 1e-3, 1e-2, 1e-1, 1.0, 1e1, 1e2 };
        return sym() * decades[pick(6)] * (0.5 + uniform());
    }
    // Moderate values, for conditioning-sensitive cases.
    double moderate() { return sym() * (0.25 + 4.0 * uniform()); }

private:
    static std::uint64_t rotl(std::uint64_t x, int k) { return (x << k) | (x >> (64 - k)); }
    std::uint64_t        s_[4];
};

inline std::uint64_t SeedFor(const std::string& name, int index) {
    std::uint64_t h = 0xcbf29ce484222325ull;
    for (char ch : name) h = (h ^ static_cast<unsigned char>(ch)) * 0x100000001b3ull;
    return h ^ (static_cast<std::uint64_t>(index) * 0x9e3779b97f4a7c15ull);
}

// --- flattening ---------------------------------------------------------------------

inline void Put(Out& o, double v) { o.push_back(v); }
inline void Put(Out& o, float v) { o.push_back(static_cast<double>(v)); }
inline void Put(Out& o, int v) { o.push_back(static_cast<double>(v)); }
inline void Put(Out& o, bool v) { o.push_back(v ? 1.0 : 0.0); }
// Any matrix or vector, column by column.
template<class M>
    requires requires(const M& m) {
        m.rows();
        m.cols();
        m(0, 0);
    }
void Put(Out& o, const M& m) {
    for (long j = 0; j < static_cast<long>(m.cols()); ++j)
        for (long i = 0; i < static_cast<long>(m.rows()); ++i)
            o.push_back(static_cast<double>(m(i, j)));
}
// A quaternion as x, y, z, w.
template<class Q>
    requires requires(const Q& q) {
        q.w();
        q.vec();
    }
void Put(Out& o, const Q& q) {
    o.push_back(static_cast<double>(q.x()));
    o.push_back(static_cast<double>(q.y()));
    o.push_back(static_cast<double>(q.z()));
    o.push_back(static_cast<double>(q.w()));
}

template<class V>
V FillVec(Rng& rng) {
    V v;
    for (long i = 0; i < static_cast<long>(v.size()); ++i)
        v(i) = static_cast<typename V::Scalar>(rng.mixed());
    return v;
}
template<class M>
M FillMat(Rng& rng) {
    M m;
    for (long j = 0; j < static_cast<long>(m.cols()); ++j)
        for (long i = 0; i < static_cast<long>(m.rows()); ++i)
            m(i, j) = static_cast<typename M::Scalar>(rng.mixed());
    return m;
}

// A rotation as nine column-major doubles from an axis and an angle, computed here
// with plain arithmetic so both libraries receive identical inputs.
inline std::array<double, 9> RotationFromAxisAngle(std::array<double, 3> axis, double angle) {
    const double n = std::sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
    for (auto& a : axis) a /= n;
    const double c = std::cos(angle), s = std::sin(angle), k = 1.0 - c;
    const double x = axis[0], y = axis[1], z = axis[2];
    return { c + k * x * x,     k * x * y + s * z, k * x * z - s * y,
             k * x * y - s * z, c + k * y * y,     k * y * z + s * x,
             k * x * z + s * y, k * y * z - s * x, c + k * z * z };
}
inline std::array<double, 3> RandomAxis(Rng& rng) {
    std::array<double, 3> a { rng.sym(), rng.sym(), rng.sym() };
    if (rng.pick(8) == 0) a = { 0.0, 0.0, 1.0 };
    if (rng.pick(8) == 0) a = { 0.0, 1.0, 0.0 };
    if (rng.pick(8) == 0) a = { 1.0, 0.0, 0.0 };
    if (std::abs(a[0]) + std::abs(a[1]) + std::abs(a[2]) < 1e-3) a = { 0.0, 0.0, 1.0 };
    return a;
}
// Angles including the special ones a rotation's branches turn on.
inline double RandomAngle(Rng& rng) {
    const double pi = 3.14159265358979323846;
    switch (rng.pick(12)) {
    case 0: return 0.0;
    case 1: return pi;
    case 2: return -pi;
    case 3: return pi / 2.0;
    case 4: return -pi / 2.0;
    case 5: return pi - 1e-9;
    case 6: return 1e-9;
    default: return rng.sym() * pi;
    }
}
template<class M3>
M3 RandomRotation(Rng& rng) {
    const auto r = RotationFromAxisAngle(RandomAxis(rng), RandomAngle(rng));
    M3         m;
    for (int k = 0; k < 9; ++k)
        m(k % 3, k / 3) = static_cast<typename M3::Scalar>(r[static_cast<std::size_t>(k)]);
    return m;
}

// --- the operations -----------------------------------------------------------------
//
// `L` names the library: its `Mat<T, R, C>`, `Aff<T>`, `Quat<T>` and friends.

template<class L, class T, int N>
void VecArith(Rng& rng, Out& o) {
    using V   = typename L::template Mat<T, N, 1>;
    const V a = FillVec<V>(rng), b = FillVec<V>(rng);
    const T s = static_cast<T>(rng.mixed());
    Put(o, V(a + b));
    Put(o, V(a - b));
    Put(o, V(-a));
    Put(o, V(a * s));
    Put(o, V(s * a));
    Put(o, V(a / s));
    V c = a;
    c += b;
    Put(o, c);
    c = a;
    c -= b;
    Put(o, c);
    c = a;
    c *= s;
    Put(o, c);
    c = a;
    c /= s;
    Put(o, c);
    // A scalar of another type converts to the vector's own before it is used.
    const double sd = rng.mixed();
    const float  sf = static_cast<float>(rng.mixed());
    const int    si = rng.pick(11) - 5;
    Put(o, V(a * sd));
    Put(o, V(sd * a));
    Put(o, V(a / sd));
    Put(o, V(a * sf));
    Put(o, V(a * si));
    Put(o, V(si * a));
}

template<class L, int N>
void VecInt(Rng& rng, Out& o) {
    using V = typename L::template Mat<int, N, 1>;
    V a, b;
    for (int i = 0; i < N; ++i) {
        a(i) = rng.pick(2001) - 1000;
        b(i) = rng.pick(2001) - 1000;
    }
    const int s = rng.pick(21) - 10;
    Put(o, V(a + b));
    Put(o, V(a - b));
    Put(o, V(-a));
    Put(o, V(a * s));
    Put(o, a == b);
    Put(o, a == V(a));
    Put(o, a.dot(b));
    Put(o, a.maxCoeff());
    Put(o, a.minCoeff());
    Put(o, a.isZero());
    Put(o, V(V::Zero()).isZero());
    Put(o, a.template cast<float>().template cast<int>());
    Put(o, a.template cast<double>());
}

template<class L, class T, int N>
void VecReduce(Rng& rng, Out& o) {
    using V   = typename L::template Mat<T, N, 1>;
    const V a = FillVec<V>(rng), b = FillVec<V>(rng);
    Put(o, a.dot(b));
    Put(o, a.squaredNorm());
    Put(o, a.norm());
    Put(o, a.sum());
    Put(o, a.maxCoeff());
    Put(o, a.minCoeff());
}

// normalized() and normalize(), including the vectors that cannot be scaled: zero,
// and ones whose square underflows or overflows.
template<class L, class T, int N>
void VecNormalize(Rng& rng, Out& o) {
    using V        = typename L::template Mat<T, N, 1>;
    V         a    = FillVec<V>(rng);
    const int kind = rng.pick(10);
    if (kind == 0) a = V::Zero();
    if (kind == 1) a = V::Constant(std::numeric_limits<T>::min() * T(4));
    if (kind == 2) a = V::Constant(std::sqrt(std::numeric_limits<T>::min()) * T(0.5));
    if (kind == 3) a = V::Constant(std::sqrt(std::numeric_limits<T>::max()) * T(2));
    if (kind == 4) a = V::Constant(std::numeric_limits<T>::denorm_min());
    Put(o, V(a.normalized()));
    V c = a;
    c.normalize();
    Put(o, c);
    Put(o, V(a.normalized()).norm());
}

template<class L, class T>
void Vec3Cross(Rng& rng, Out& o) {
    using V   = typename L::template Mat<T, 3, 1>;
    const V a = FillVec<V>(rng), b = FillVec<V>(rng);
    Put(o, V(a.cross(b)));
    Put(o, V(b.cross(a)));
    Put(o, V(a.cross(a)));
    Put(o, V(a.cross(b).normalized()));
}

template<class L, class T, int N>
void VecCwise(Rng& rng, Out& o) {
    using V   = typename L::template Mat<T, N, 1>;
    const V a = FillVec<V>(rng), b = FillVec<V>(rng);
    Put(o, V(a.cwiseProduct(b)));
    Put(o, V(a.cwiseMin(b)));
    Put(o, V(a.cwiseMax(b)));
    Put(o, V(a.cwiseAbs()));
    Put(o, a.cwiseAbs().maxCoeff());
    Put(o, V((a - b).cwiseAbs()).maxCoeff());
}

// isApprox in its three precisions, against vectors from identical to far, and the
// zero cases the engine's dirty checks hit.
template<class L, class T, int N>
void VecPredicates(Rng& rng, Out& o) {
    using V     = typename L::template Mat<T, N, 1>;
    const V   a = FillVec<V>(rng);
    const int k = rng.pick(8);
    V         b = a;
    if (k == 1) b = a * static_cast<T>(1.0 + 1e-8);
    if (k == 2) b = a * static_cast<T>(1.0 + 1e-3);
    if (k == 3) b = a * static_cast<T>(1.0 + 1e-6);
    if (k == 4) b = FillVec<V>(rng);
    if (k == 5) b = V::Zero();
    if (k == 6) b(0) = a(0) + static_cast<T>(1e-7);
    const V zero = V::Zero();
    Put(o, a.isApprox(b));
    Put(o, a.isApprox(b, static_cast<T>(1e-3)));
    Put(o, a.isApprox(b, static_cast<T>(1e-6)));
    Put(o, a.isApprox(b, static_cast<T>(0)));
    Put(o, b.isApprox(a, static_cast<T>(0)));
    Put(o, a.isApprox(zero));
    Put(o, zero.isApprox(a));
    Put(o, zero.isApprox(zero));
    Put(o, zero.isApprox(zero, static_cast<T>(0)));
    Put(o, a == b);
    Put(o, a == a);
    Put(o, V(a * static_cast<T>(1e-9)).isZero());
    Put(o, V(a * static_cast<T>(1e-3)).isZero(static_cast<T>(1e-3)));
    Put(o, V(a * static_cast<T>(1e-3)).isZero(static_cast<T>(1e-9)));
    Put(o, zero.isZero());
    const V nearOnes = V::Ones() * static_cast<T>(1.0 + 1e-7 * (k - 3));
    Put(o, nearOnes.isOnes());
    Put(o, nearOnes.isOnes(static_cast<T>(1e-3)));
    Put(o, nearOnes.isOnes(static_cast<T>(0)));
    Put(o, V::Ones().isOnes(static_cast<T>(0)));
    Put(o, a.isOnes());
    Put(o, a.isApproxToConstant(a(0)));
    Put(o, V::Constant(a(0)).isApproxToConstant(a(0), static_cast<T>(0)));
    V bad = a;
    if (k == 0) bad(rng.pick(N)) = std::numeric_limits<T>::infinity();
    if (k == 1) bad(rng.pick(N)) = std::numeric_limits<T>::quiet_NaN();
    Put(o, a.allFinite());
    Put(o, bad.allFinite());
}

template<class L, class T, int N>
void VecCast(Rng& rng, Out& o) {
    using V = typename L::template Mat<T, N, 1>;
    V a     = FillVec<V>(rng);
    // The int casts truncate, so keep inside int's range.
    V small = a;
    for (int i = 0; i < N; ++i)
        small(i) = static_cast<T>(std::fmod(static_cast<double>(a(i)), 1.0e6));
    Put(o, a.template cast<float>());
    Put(o, a.template cast<double>());
    Put(o, small.template cast<int>());
    Put(o, a.template cast<float>().template cast<double>());
    Put(o, a.template cast<double>().template cast<float>());
}

// Views that write through: the editing the scene graph does to its matrices.
template<class L, class T>
void MatViews(Rng& rng, Out& o) {
    using M4   = typename L::template Mat<T, 4, 4>;
    using M3   = typename L::template Mat<T, 3, 3>;
    using V3   = typename L::template Mat<T, 3, 1>;
    using V4   = typename L::template Mat<T, 4, 1>;
    M4       m = FillMat<M4>(rng);
    const V3 v = FillVec<V3>(rng), w = FillVec<V3>(rng);
    const V4 q = FillVec<V4>(rng);
    m.template block<3, 1>(0, 3) += v;
    Put(o, m);
    m.template block<3, 1>(0, 3) = w;
    m.template block<3, 3>(0, 0) = FillMat<M3>(rng);
    Put(o, m);
    m.col(1) = q;
    m.row(2) = q.transpose();
    Put(o, m);
    m.col(0).template head<3>() = v;
    m.template topRightCorner<3, 1>() -= w;
    Put(o, m);
    m.template topLeftCorner<3, 3>() *= static_cast<T>(2.5);
    m.col(3) /= static_cast<T>(3.0);
    Put(o, m);
    const M3 lin = m.template topLeftCorner<3, 3>();
    const V3 pos = m.template topRightCorner<3, 1>();
    Put(o, lin);
    Put(o, pos);
    Put(o, V3((m * q).template head<3>()));
    Put(o, V3((m * q).template head<3>() / (m * q).w()));
    Put(o, V3(m.template block<3, 1>(0, 1).normalized()));
    Put(o, V3(m.template block<3, 3>(0, 0).col(2)));
    Put(o, m.template block<2, 1>(0, 3));
    // Predicates and norms through a view.
    Put(o, m.template block<3, 3>(0, 0).isApprox(lin));
    Put(o,
        m.template block<3, 3>(0, 0).isApprox(lin * static_cast<T>(1.0 + 1e-6),
                                              static_cast<T>(1e-3)));
    Put(o, m.template block<3, 3>(0, 0).isIdentity());
    Put(o, m.template block<3, 1>(0, 3).isZero());
    Put(o, m.template block<3, 1>(0, 3).isApprox(pos, static_cast<T>(0)));
    Put(o, m.template block<3, 1>(0, 3).norm());
    Put(o, m.template block<3, 3>(0, 0).colwise().norm());
    Put(o, m.template block<3, 1>(0, 3).allFinite());
    Put(o, m.template block<3, 1>(0, 3) == pos);
}

template<class L, class T, int N>
void MatProduct(Rng& rng, Out& o) {
    using M   = typename L::template Mat<T, N, N>;
    using V   = typename L::template Mat<T, N, 1>;
    const M a = FillMat<M>(rng), b = FillMat<M>(rng);
    const V v = FillVec<V>(rng);
    const T s = static_cast<T>(rng.mixed());
    Put(o, M(a * b));
    Put(o, V(a * v));
    Put(o, M(a + b));
    Put(o, M(a - b));
    Put(o, M(-a));
    Put(o, M(a * s));
    Put(o, M(s * a));
    Put(o, M(a / s));
    Put(o, M(a.transpose()));
    Put(o, a == b);
    Put(o, a == M(a));
    M c = a;
    c += b;
    Put(o, c);
    c = a;
    c -= b;
    Put(o, c);
    c = M::Identity();
    c *= s;
    Put(o, c);
    // A product whose factors are read through views, as the engine's affine code does.
    Put(o, V((a * b) * v));
    Put(o, V(a * (b * v)));
}

// The non-square products the affine code runs: 3x3 * 3x4 and 3x4 * 4x4, and a 3x3
// times the strided 3x1 column of a 4x4.
template<class L, class T>
void MatProductShapes(Rng& rng, Out& o) {
    using M34   = typename L::template Mat<T, 3, 4>;
    using M44   = typename L::template Mat<T, 4, 4>;
    using M33   = typename L::template Mat<T, 3, 3>;
    using V3    = typename L::template Mat<T, 3, 1>;
    using V4    = typename L::template Mat<T, 4, 1>;
    using R4    = typename L::template Mat<T, 1, 4>;
    using R3    = typename L::template Mat<T, 1, 3>;
    const M33 r = FillMat<M33>(rng);
    const M34 t = FillMat<M34>(rng);
    const M44 m = FillMat<M44>(rng);
    const V3  v = FillVec<V3>(rng);
    const V4  q = FillVec<V4>(rng);
    Put(o, M34(r * t));
    Put(o, M34(t * m));
    Put(o, V3(t * q));
    Put(o, V3(m.template block<3, 3>(0, 0) * v));
    Put(o, M33(m.template block<3, 3>(0, 0) * r));
    Put(o, M34(m.template block<3, 4>(0, 0) * m));
    Put(o, M34(r * m.template block<3, 4>(0, 0)));
    Put(o, V3(r * m.template block<3, 1>(0, 3)));
    Put(o, (R3(v.transpose()) * v)(0, 0));
    Put(o, (R4(q.transpose()) * q)(0, 0));
}

// The values that break a naive formula: infinities, NaN, signed zeros, the largest
// and smallest magnitudes. A library has to propagate them like IEEE arithmetic does.
template<class T>
T SpecialValue(Rng& rng) {
    switch (rng.pick(12)) {
    case 0: return T(0);
    case 1: return -T(0);
    case 2: return std::numeric_limits<T>::infinity();
    case 3: return -std::numeric_limits<T>::infinity();
    case 4: return std::numeric_limits<T>::quiet_NaN();
    case 5: return std::numeric_limits<T>::max();
    case 6: return -std::numeric_limits<T>::max();
    case 7: return std::numeric_limits<T>::min();
    case 8: return std::numeric_limits<T>::denorm_min();
    case 9: return T(1);
    case 10: return T(-1);
    default: return static_cast<T>(rng.mixed());
    }
}

template<class L, class T, int N>
void VecEdge(Rng& rng, Out& o) {
    using V = typename L::template Mat<T, N, 1>;
    V a, b;
    for (int i = 0; i < N; ++i) {
        a(i) = SpecialValue<T>(rng);
        b(i) = SpecialValue<T>(rng);
    }
    const T s = SpecialValue<T>(rng);
    Put(o, V(a + b));
    Put(o, V(a - b));
    Put(o, V(a * s));
    Put(o, V(a / s));
    Put(o, a.dot(b));
    Put(o, a.squaredNorm());
    Put(o, a.norm());
    Put(o, a.sum());
    Put(o, V(a.normalized()));
    V c = a;
    c.normalize();
    Put(o, c);
    Put(o, V(a.cwiseProduct(b)));
    Put(o, V(a.cwiseAbs()));
    Put(o, a.isApprox(b));
    Put(o, a.isApprox(a));
    Put(o, a.isApprox(b, static_cast<T>(0)));
    Put(o, a.isZero());
    Put(o, a.allFinite());
    Put(o, a == b);
    Put(o, a == a);
    if constexpr (N == 3) {
        Put(o, V(a.cross(b)));
    }
    Put(o, a.template cast<float>());
    Put(o, a.template cast<double>());
}

template<class L, class T, int N>
void MatEdge(Rng& rng, Out& o) {
    using M = typename L::template Mat<T, N, N>;
    using V = typename L::template Mat<T, N, 1>;
    M a, b;
    V v;
    for (int j = 0; j < N; ++j) {
        v(j) = SpecialValue<T>(rng);
        for (int i = 0; i < N; ++i) {
            a(i, j) = SpecialValue<T>(rng);
            b(i, j) = SpecialValue<T>(rng);
        }
    }
    Put(o, M(a * b));
    Put(o, V(a * v));
    Put(o, M(a + b));
    Put(o, M(a * SpecialValue<T>(rng)));
    Put(o, a.isApprox(b));
    Put(o, a.isApprox(a));
    Put(o, a.isIdentity());
    Put(o, a.allFinite());
    Put(o, a == b);
    Put(o, a.squaredNorm());
    Put(o, a.norm());
}

template<class L, class T>
void AffineEdge(Rng& rng, Out& o) {
    using A  = typename L::template Aff<T>;
    using V3 = typename L::template Mat<T, 3, 1>;
    using AA = typename L::template AA<T>;
    A  a     = A::Identity();
    V3 v, w;
    for (int i = 0; i < 3; ++i) {
        v(i) = SpecialValue<T>(rng);
        w(i) = SpecialValue<T>(rng);
    }
    a.prescale(v);
    Put(o, a.matrix());
    a.pretranslate(w);
    Put(o, a.matrix());
    a.scale(w);
    Put(o, a.matrix());
    a.translate(v);
    Put(o, a.matrix());
    a.prerotate(AA(static_cast<T>(RandomAngle(rng)), V3::UnitZ()));
    Put(o, a.matrix());
    Put(o, V3(a * v));
    Put(o, A((a * a).matrix()).matrix());
}

// A view over raw floats, a vector built from a pointer, and coefficient-wise array
// arithmetic: the odd corners the particle parser and the shader uniform code use.
template<class L, class T>
void MapAndArrays(Rng& rng, Out& o) {
    using M4 = typename L::template Mat<T, 4, 4>;
    using V3 = typename L::template Mat<T, 3, 1>;
    using V4 = typename L::template Mat<T, 4, 1>;
    std::array<T, 16> raw {};
    for (auto& v : raw) v = static_cast<T>(rng.mixed());
    const M4 viaMap = L::template CMap<M4>(raw.data());
    Put(o, viaMap);
    const V3 fromPtr(raw.data() + 3);
    Put(o, fromPtr);
    Put(o, V4(raw.data()));
    Put(o, M4(L::template CMap<M4>(raw.data()) * viaMap));
    const V3 a = FillVec<V3>(rng), b = a * static_cast<T>(rng.pick(2));
    Put(o, (a.array() == b.array()).all());
    Put(o, (a.array() == a.array()).all());
    const double phase = rng.mixed(), scale = rng.mixed();
    using D3   = typename L::template Mat<double, 3, 1>;
    const D3 q = ((a.template cast<double>().array() + phase) * scale).matrix();
    Put(o, q);
    const D3 r = ((a.template cast<double>().array() * scale) + (-phase)).matrix();
    Put(o, r);
    using V2    = typename L::template Mat<T, 2, 1>;
    const V2 xy = FillVec<V2>(rng);
    Put(o, V2(L::template Scale<T>(static_cast<T>(1), static_cast<T>(-1)) * xy));
    Put(o, V2(L::template Scale<T>(static_cast<T>(rng.mixed()), static_cast<T>(rng.mixed())) * xy));
    Put(o, V4(a.homogeneous()));
    Put(o, typename L::template Mat<double, 4, 1>(a.template cast<double>().homogeneous()));
    M4 c     = M4::Identity();
    c.col(1) = -c.col(1);
    c.col(2) /= static_cast<T>(rng.moderate());
    Put(o, c);
}

// The inverse and determinant of the matrices the scene graph actually has: a scale, a
// rotation and a translation. The 4 x 4 cofactor routines are not bit-for-bit the other
// library's, so these carry a tolerance.
template<class L, class T>
void MatTrs(Rng& rng, Out& o) {
    using M4 = typename L::template Mat<T, 4, 4>;
    using V3 = typename L::template Mat<T, 3, 1>;
    using A  = typename L::template Aff<T>;
    using AA = typename L::template AA<T>;
    A a      = A::Identity();
    a.prescale(V3(static_cast<T>(0.1 + 9.9 * rng.uniform()),
                  static_cast<T>(0.1 + 9.9 * rng.uniform()),
                  static_cast<T>(0.1 + 9.9 * rng.uniform())));
    a.prerotate(AA(static_cast<T>(RandomAngle(rng)), V3::UnitZ()));
    a.prerotate(AA(static_cast<T>(RandomAngle(rng)), V3::UnitX()));
    a.pretranslate(V3(static_cast<T>(rng.moderate() * 100),
                      static_cast<T>(rng.moderate() * 100),
                      static_cast<T>(rng.moderate())));
    const M4 m = a.matrix();
    Put(o, m.determinant());
    Put(o, M4(m.inverse()));
}

template<class L, class T, int N>
void MatDetInv(Rng& rng, Out& o) {
    using M = typename L::template Mat<T, N, N>;
    M m;
    for (int j = 0; j < N; ++j)
        for (int i = 0; i < N; ++i) m(i, j) = static_cast<T>(rng.moderate());
    Put(o, m.determinant());
    Put(o, M(m.inverse()));
    Put(o, M(m.inverse() * m));
}

template<class L, class T, int N>
void MatPredicates(Rng& rng, Out& o) {
    using M     = typename L::template Mat<T, N, N>;
    const M   a = FillMat<M>(rng);
    const int k = rng.pick(6);
    M         b = a;
    if (k == 1) b = a * static_cast<T>(1.0 + 1e-8);
    if (k == 2) b = a * static_cast<T>(1.0 + 1e-3);
    if (k == 3) b = FillMat<M>(rng);
    if (k == 4) b(0, 0) = a(0, 0) + static_cast<T>(1e-7);
    M near = M::Identity();
    if (k == 0) near(1, 1) += static_cast<T>(1e-9);
    if (k == 1) near(0, N - 1) += static_cast<T>(1e-9);
    if (k == 2) near(0, 0) += static_cast<T>(1e-3);
    Put(o, a.isApprox(b));
    Put(o, a.isApprox(b, static_cast<T>(1e-3)));
    Put(o, a.isApprox(b, static_cast<T>(0)));
    Put(o, a.isApprox(M::Zero()));
    Put(o, M(M::Zero()).isApprox(M::Zero()));
    Put(o, near.isIdentity());
    Put(o, near.isIdentity(static_cast<T>(1e-6)));
    Put(o, near.isIdentity(static_cast<T>(0)));
    Put(o, M::Identity().isIdentity(static_cast<T>(0)));
    Put(o, a.isIdentity());
    Put(o, a == b);
    Put(o, a.squaredNorm());
    Put(o, a.norm());
    Put(o, (a - b).squaredNorm());
    Put(o, a.allFinite());
    Put(o, a.maxCoeff());
    Put(o, a.minCoeff());
    Put(o, M(a.cwiseAbs()));
}

template<class L, class T, int N>
void MatColwise(Rng& rng, Out& o) {
    using M   = typename L::template Mat<T, N, N>;
    const M a = FillMat<M>(rng);
    Put(o, a.colwise().norm());
    typename L::template Mat<T, N, 1> v = a.colwise().norm();
    Put(o, v);
    M c = a;
    for (auto col : c.colwise())
        for (auto& x : col) x = x + T(1);
    Put(o, c);
}

template<class L, class T>
void RotationAA(Rng& rng, Out& o) {
    using V3         = typename L::template Mat<T, 3, 1>;
    using M3         = typename L::template Mat<T, 3, 3>;
    using AA         = typename L::template AA<T>;
    using Q          = typename L::template Quat<T>;
    const auto   ax  = RandomAxis(rng);
    const double nrm = std::sqrt(ax[0] * ax[0] + ax[1] * ax[1] + ax[2] * ax[2]);
    V3 axis(static_cast<T>(ax[0] / nrm), static_cast<T>(ax[1] / nrm), static_cast<T>(ax[2] / nrm));
    const T  a1 = static_cast<T>(RandomAngle(rng)), a2 = static_cast<T>(RandomAngle(rng));
    const AA r1(a1, axis), r2(a2, V3::UnitY()), r3(a2, V3::UnitZ());
    Put(o, M3(r1.toRotationMatrix()));
    Put(o, M3(r2.toRotationMatrix()));
    const V3 v = FillVec<V3>(rng);
    Put(o, V3(r1 * v));
    Put(o, M3(r1 * FillMat<M3>(rng)));
    Put(o, Q(Q(r1)));
    Put(o, Q(r1 * r2));
    Put(o, Q(r3 * r2 * r1));
    Put(o, M3((r3 * r2 * r1).toRotationMatrix()));
    Put(o, a1 == r1.angle() ? T(1) : T(0));
    Put(o, V3(r1.axis()));
}

template<class L, class T>
void QuatOps(Rng& rng, Out& o) {
    using V3 = typename L::template Mat<T, 3, 1>;
    using M3 = typename L::template Mat<T, 3, 3>;
    using Q  = typename L::template Quat<T>;
    const Q a(static_cast<T>(rng.mixed()),
              static_cast<T>(rng.mixed()),
              static_cast<T>(rng.mixed()),
              static_cast<T>(rng.mixed()));
    const Q b(static_cast<T>(rng.mixed()),
              static_cast<T>(rng.mixed()),
              static_cast<T>(rng.mixed()),
              static_cast<T>(rng.mixed()));
    Put(o, a);
    Put(o, Q(a * b));
    Q c = a;
    c *= b;
    Put(o, c);
    Put(o, Q(a.conjugate()));
    Put(o, Q(a.normalized()));
    Put(o, a.squaredNorm());
    Put(o, a.norm());
    Put(o, a.dot(b));
    Put(o, M3(a.normalized().toRotationMatrix()));
    Put(o, Q(Q::Identity()));
    Put(o, typename L::template Quat<double>(a.template cast<double>()));
    Put(o, typename L::template Quat<float>(a.template cast<float>()));
    Put(o, V3(a.vec()));
    Put(o, a.w());
}

// Quaternion from a rotation matrix, in the four branches the conversion has (trace
// positive, or each of the three diagonal entries largest).
template<class L, class T>
void QuatFromMatrix(Rng& rng, Out& o) {
    using M3 = typename L::template Mat<T, 3, 3>;
    using Q  = typename L::template Quat<T>;
    M3 m     = RandomRotation<M3>(rng);
    if (rng.pick(6) == 0) m = M3(m * static_cast<T>(2.0)); // not a rotation: still defined
    Put(o, Q(m));
    Put(o, Q(Q(m).normalized()));
    Put(o, M3(Q(m).normalized().toRotationMatrix()));
    // A rotation by pi about each axis puts the largest entry on a different diagonal.
    const int axis = rng.pick(3);
    M3        flip = M3::Identity();
    for (int i = 0; i < 3; ++i) flip(i, i) = i == axis ? T(1) : T(-1);
    Put(o, Q(flip));
    Put(o, Q(M3(m * flip)));
}

template<class L, class T>
void QuatSlerp(Rng& rng, Out& o) {
    using Q    = typename L::template Quat<T>;
    using V4   = typename L::template Mat<T, 4, 1>;
    auto unitQ = [&]() {
        V4 c = FillVec<V4>(rng);
        if (c.squaredNorm() == T(0)) c = V4(T(0), T(0), T(0), T(1));
        c.normalize();
        return Q(c(3), c(0), c(1), c(2));
    };
    const Q   a = unitQ();
    Q         b = unitQ();
    const int k = rng.pick(8);
    if (k == 0) b = a;                                 // dot = 1
    if (k == 1) b = Q(-a.w(), -a.x(), -a.y(), -a.z()); // dot = -1
    if (k == 2) b = Q(a.w() * static_cast<T>(0.99999999), a.x(), a.y(), a.z()).normalized();
    if (k == 3) b = Q(-a.w() * static_cast<T>(0.9999999), -a.x(), -a.y(), -a.z()).normalized();
    if (k == 4) b = Q::Identity();
    const double t = rng.pick(5) == 0 ? (rng.pick(2) ? 0.0 : 1.0) : rng.uniform();
    Put(o, Q(a.slerp(static_cast<T>(t), b)));
    Put(o, Q(a.slerp(static_cast<T>(t), b).slerp(static_cast<T>(1.0 - t), Q::Identity())));
    Put(o, Q(a.slerp(static_cast<T>(1.5), b)));
    Put(o, a.dot(b));
}

// The Euler angles of rotations, in the order the engine uses and in the others.
template<class L, class T>
void EulerAngles(Rng& rng, Out& o) {
    using M3 = typename L::template Mat<T, 3, 3>;
    using V3 = typename L::template Mat<T, 3, 1>;
    M3        m;
    const int kind = rng.pick(10);
    if (kind == 0 || kind == 1) {
        // R = Rz Ry Rx with the middle angle at or next to the pole.
        const double pole[] = { 1.5707963267948966, -1.5707963267948966 };
        const double near[] = { 0.0, 1e-12, -1e-12, 1e-7, -1e-7 };
        const double y      = pole[rng.pick(2)] + near[rng.pick(5)];
        const auto   rz     = RotationFromAxisAngle({ 0, 0, 1 }, RandomAngle(rng));
        const auto   ry     = RotationFromAxisAngle({ 0, 1, 0 }, y);
        const auto   rx     = RotationFromAxisAngle({ 1, 0, 0 }, RandomAngle(rng));
        auto         mul    = [](const std::array<double, 9>& p, const std::array<double, 9>& q) {
            std::array<double, 9> r {};
            for (int i = 0; i < 3; ++i)
                for (int j = 0; j < 3; ++j)
                    for (int k = 0; k < 3; ++k)
                        r[static_cast<std::size_t>(i + 3 * j)] +=
                            p[static_cast<std::size_t>(i + 3 * k)] *
                            q[static_cast<std::size_t>(k + 3 * j)];
            return r;
        };
        const auto r = mul(mul(rz, ry), rx);
        for (int k = 0; k < 9; ++k)
            m(k % 3, k / 3) = static_cast<T>(r[static_cast<std::size_t>(k)]);
    } else {
        m = RandomRotation<M3>(rng);
    }
    Put(o, V3(m.eulerAngles(2, 1, 0)));
    const int orders[6][3] = { { 0, 1, 2 }, { 0, 2, 1 }, { 1, 0, 2 },
                               { 1, 2, 0 }, { 2, 0, 1 }, { 2, 1, 0 } };
    const int (&ord)[3]    = orders[rng.pick(6)];
    Put(o, V3(m.eulerAngles(ord[0], ord[1], ord[2])));
    // The angles rebuild the rotation.
    const V3 e = m.eulerAngles(2, 1, 0);
    using AA   = typename L::template AA<T>;
    const M3 back =
        (AA(e(0), V3::UnitZ()) * AA(e(1), V3::UnitY()) * AA(e(2), V3::UnitX())).toRotationMatrix();
    Put(o, back);
}

// Chains of the six affine edits, the way SceneNode and the particle code compose them.
template<class L, class T>
void AffineChain(Rng& rng, Out& o) {
    using A         = typename L::template Aff<T>;
    using V3        = typename L::template Mat<T, 3, 1>;
    using AA        = typename L::template AA<T>;
    using Q         = typename L::template Quat<T>;
    A         a     = A::Identity();
    const int steps = 1 + rng.pick(6);
    for (int s = 0; s < steps; ++s) {
        const V3     v   = FillVec<V3>(rng);
        const auto   ax  = RandomAxis(rng);
        const double nrm = std::sqrt(ax[0] * ax[0] + ax[1] * ax[1] + ax[2] * ax[2]);
        const V3     axis(
            static_cast<T>(ax[0] / nrm), static_cast<T>(ax[1] / nrm), static_cast<T>(ax[2] / nrm));
        const AA rot(static_cast<T>(RandomAngle(rng)), axis);
        switch (rng.pick(8)) {
        case 0: a.prescale(v); break;
        case 1: a.scale(v); break;
        case 2: a.prerotate(rot); break;
        case 3: a.rotate(rot); break;
        case 4: a.pretranslate(v); break;
        case 5: a.translate(v); break;
        case 6: a.rotate(Q(rot)); break;
        default: a.prerotate(Q(rot)); break;
        }
        Put(o, a.matrix());
    }
    Put(o, typename L::template Mat<T, 3, 3>(a.linear()));
    Put(o, V3(a.translation()));
}

template<class L, class T>
void AffineProducts(Rng& rng, Out& o) {
    using A   = typename L::template Aff<T>;
    using V3  = typename L::template Mat<T, 3, 1>;
    using M4  = typename L::template Mat<T, 4, 4>;
    using AA  = typename L::template AA<T>;
    auto make = [&]() {
        A a = A::Identity();
        a.prescale(V3(static_cast<T>(rng.moderate()),
                      static_cast<T>(rng.moderate()),
                      static_cast<T>(rng.moderate())));
        a.prerotate(AA(static_cast<T>(RandomAngle(rng)), V3::UnitZ()));
        a.prerotate(AA(static_cast<T>(RandomAngle(rng)), V3::UnitX()));
        a.pretranslate(FillVec<V3>(rng));
        return a;
    };
    const A a = make(), b = make();
    Put(o, M4((a * b).matrix()));
    Put(o, V3(a * FillVec<V3>(rng)));
    Put(o, M4(a.inverse().matrix()));
    Put(o, M4((a * a.inverse()).matrix()));
    A c = a;
    c *= b.matrix();
    Put(o, c.matrix());
    c = a;
    c *= typename L::template Trans<T>(FillVec<V3>(rng));
    Put(o, c.matrix());
    Put(o, M4(a * b.matrix()));
    Put(o, M4(A(typename L::template Trans<T>(FillVec<V3>(rng))).matrix()));
    Put(o,
        M4(A(L::template Scale<T>(static_cast<T>(rng.moderate()),
                                  static_cast<T>(rng.moderate()),
                                  static_cast<T>(rng.moderate())))
               .matrix()));
    A d               = A::Identity();
    d.linear().col(0) = FillVec<V3>(rng);
    d.linear().col(1) = FillVec<V3>(rng);
    d.linear().col(2) = FillVec<V3>(rng);
    d.translation()   = FillVec<V3>(rng);
    Put(o, d.matrix());
    d.translation() += FillVec<V3>(rng);
    Put(o, d.matrix());
    Put(o, M4(A(a.matrix()).matrix()));
}

template<class L>
void ProjectiveOps(Rng& rng, Out& o) {
    using P  = typename L::Proj3d;
    using V3 = typename L::template Mat<double, 3, 1>;
    using M4 = typename L::template Mat<double, 4, 4>;
    P p      = P::Identity();
    for (int s = 0; s < 4; ++s) {
        const V3 v = FillVec<V3>(rng);
        switch (rng.pick(5)) {
        case 0: p.prescale(v); break;
        case 1: p.scale(v); break;
        case 2: p.pretranslate(v); break;
        case 3: p.translate(v); break;
        default: p(3, rng.pick(4)) = rng.mixed(); break;
        }
        Put(o, p.matrix());
    }
    Put(o, M4(p.matrix()));
}

template<class L>
void CameraMatrices(Rng& rng, Out& o) {
    using V3       = typename L::template Mat<double, 3, 1>;
    const double l = rng.moderate(), r = l + 0.1 + 4.0 * rng.uniform(), b = rng.moderate(),
                 t = b + 0.1 + 4.0 * rng.uniform();
    const double n = 0.05 + rng.uniform(), f = n + 0.5 + 100.0 * rng.uniform();
    Put(o, L::Radians(rng.mixed() * 100.0));
    Put(o, L::Ortho(l, r, b, t, n, f));
    Put(o, L::Perspective(0.2 + 2.0 * rng.uniform(), 0.5 + 2.0 * rng.uniform(), n, f));
    const V3 eye = FillVec<V3>(rng), center = FillVec<V3>(rng), up = FillVec<V3>(rng);
    Put(o, L::LookAt(eye, center, up));
    Put(o, L::LookAt(eye, eye, up));
}

// FullPivLU's verdict and inverse on 4x4 matrices: well conditioned, rank deficient
// in each way, and a hair from singular.
template<class L>
void LuInverse(Rng& rng, Out& o) {
    using M4 = typename L::template Mat<double, 4, 4>;
    using LU = typename L::template LU<M4>;
    M4 m;
    for (int j = 0; j < 4; ++j)
        for (int i = 0; i < 4; ++i) m(i, j) = rng.moderate();
    const int kind = rng.pick(12);
    if (kind == 0) m.col(2) = m.col(1);
    if (kind == 1) m.row(3) = m.row(0) * 2.0;
    if (kind == 2) m = M4::Zero();
    if (kind == 3) m.col(3).setZero();
    if (kind == 4) m.row(1) *= 1e-17;
    if (kind == 5) m.col(0) *= 1e-13;
    if (kind == 6) m(0, 0) += 1e300;
    if (kind == 7) m = M4::Identity() * 1e-200;
    if (kind == 8) {
        m.col(1) = m.col(0) * (1.0 + 1e-15);
    }
    const LU   lu(m);
    const bool inv = lu.isInvertible();
    Put(o, inv);
    if (inv) {
        const M4 x = lu.inverse();
        Put(o, x);
    }
}

// Model matrices the scene graph can end up with when a layer is scaled to nothing, and
// matrices that are singular in other ways, all with entries a few digits long so that
// the determinant is exactly zero: the inverse of a singular matrix must divide by that
// zero the same way, giving the same infinities and NaNs. (A singular matrix whose
// entries carry rounding noise, such as a rotated one, has a determinant that is not
// exactly zero in any order of evaluation, and the 4 x 4 inverse of those is only
// within the documented limits; see `Matrix4d` in Utils/LinalgDense.hpp.)
template<class L, class T>
void SingularModelInverse(Rng& rng, Out& o) {
    using M4 = typename L::template Mat<T, 4, 4>;
    using A  = typename L::template Aff<T>;
    static constexpr double table[10][16] = {
        { 0, 0, 0, 5, 0, 2, 0, -1, 0, 0, 3, 7, 0, 0, 0, 1 },
        { 2, 0, 0, 5, 0, 0, 0, -1, 0, 0, 3, 7, 0, 0, 0, 1 },
        { 2, 0, 0, 5, 0, 4, 0, -1, 0, 0, 0, 7, 0, 0, 0, 1 },
        { 0, 0, 0, 5, 0, 0, 0, -1, 0, 0, 0, 7, 0, 0, 0, 1 },
        { 0, -1.6, 0, 5, 0, 1.2, 0, -1, 0, 0, 3, 7, 0, 0, 0, 1 },
        { 1.2, -3.2, 0, 5, 1.6, 2.4, 0, -1, 0, 0, 0, 7, 0, 0, 0, 1 },
        { 2, 0, 0, 5, 0, 0, -2.4, -1, 0, 0, 1.8, 7, 0, 0, 0, 1 },
        { 1, 2, 3, 4, 0, 0, 0, 0, 5, 6, 7, 8, 9, 1, 2, 3 },
        { 1, 2, 2, 4, 5, 6, 6, 8, 9, 1, 1, 3, 2, 7, 7, 5 },
        { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 },
    };
    const auto& row = table[rng.pick(10)];
    M4          m;
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j) m(i, j) = static_cast<T>(row[i * 4 + j]);
    Put(o, m.determinant());
    Put(o, M4(m.inverse()));
    A a;
    a.matrix() = m;
    Put(o, M4(a.inverse().matrix()));
}

// A rotated layer scaled to nothing on one axis, inverted as a transform (the engine's
// own path for camera and model transforms is the 4 x 4 inverse, but this is the
// transform inverse, whose result must match bit for bit), and judged by the LU.
template<class L, class T>
void ZeroScaleAffine(Rng& rng, Out& o) {
    using M4 = typename L::template Mat<T, 4, 4>;
    using V3 = typename L::template Mat<T, 3, 1>;
    using A  = typename L::template Aff<T>;
    using AA = typename L::template AA<T>;
    T s[3]   = { static_cast<T>(0.1 + 9.9 * rng.uniform()),
                 static_cast<T>(0.1 + 9.9 * rng.uniform()),
                 static_cast<T>(0.1 + 9.9 * rng.uniform()) };
    s[rng.pick(3)] = T(0);
    A a            = A::Identity();
    a.prescale(V3(s[0], s[1], s[2]));
    a.prerotate(AA(static_cast<T>(RandomAngle(rng)), V3::UnitZ()));
    a.prerotate(AA(static_cast<T>(RandomAngle(rng)), V3::UnitX()));
    a.pretranslate(V3(static_cast<T>(rng.moderate() * 100),
                      static_cast<T>(rng.moderate() * 100),
                      static_cast<T>(rng.moderate())));
    Put(o, M4(a.inverse().matrix()));
    const M4 m = a.matrix();
    using LU   = typename L::template LU<typename L::template Mat<double, 4, 4>>;
    Put(o, LU(m.template cast<double>()).isInvertible());
}

// --- the registry -------------------------------------------------------------------

// What a case demands of a library. `vsOther` means the bits of every result match the
// reference library's. A case that calls the C library's trigonometry (`usesLibm`) is
// bit-exact against a library on the same machine but can legitimately move across
// operating systems, so its golden hash is enforced only where a canary of libm results
// still reproduces. A case with a tolerance (`tol` > 0) is not bit-exact by design (a
// matrix inverse, say); its golden values are stored and compared within `tol`,
// relative to the larger of 1 and the value.
struct Spec {
    const char* name;
    int         cases;
    bool        vsOtherExact;
    bool        usesLibm;
    double      tol;
};

template<class L>
struct Op {
    Spec spec;
    void (*run)(Rng&, Out&);
};

template<class L>
std::vector<Op<L>> Registry() {
    constexpr int      kMany = 4000, kSome = 600, kFew = 48;
    std::vector<Op<L>> r;
    auto               add = [&](const char* name,
                   int         cases,
                   bool        exact,
                   bool        libm,
                   double      tol,
                   void (*fn)(Rng&, Out&)) {
        r.push_back({ { name, cases, exact, libm, tol }, fn });
    };
#define LINALG_VEC_OPS(T, TN, N)                                                    \
    add("vec" #N TN ".arith", kMany, true, false, 0, &VecArith<L, T, N>);           \
    add("vec" #N TN ".reduce", kMany, true, false, 0, &VecReduce<L, T, N>);         \
    add("vec" #N TN ".normalize", kMany, true, false, 0, &VecNormalize<L, T, N>);   \
    add("vec" #N TN ".cwise", kMany, true, false, 0, &VecCwise<L, T, N>);           \
    add("vec" #N TN ".predicates", kMany, true, false, 0, &VecPredicates<L, T, N>); \
    add("vec" #N TN ".cast", kMany, true, false, 0, &VecCast<L, T, N>);
    LINALG_VEC_OPS(float, "f", 2)
    LINALG_VEC_OPS(float, "f", 3)
    LINALG_VEC_OPS(float, "f", 4)
    LINALG_VEC_OPS(double, "d", 2)
    LINALG_VEC_OPS(double, "d", 3)
    LINALG_VEC_OPS(double, "d", 4)
#undef LINALG_VEC_OPS
    add("vec2i.ops", kMany, true, false, 0, &VecInt<L, 2>);
    add("vec3i.ops", kMany, true, false, 0, &VecInt<L, 3>);
    add("vec4i.ops", kMany, true, false, 0, &VecInt<L, 4>);
    add("vec2f.edge", kMany, true, false, 0, &VecEdge<L, float, 2>);
    add("vec3f.edge", kMany, true, false, 0, &VecEdge<L, float, 3>);
    add("vec4f.edge", kMany, true, false, 0, &VecEdge<L, float, 4>);
    add("vec2d.edge", kMany, true, false, 0, &VecEdge<L, double, 2>);
    add("vec3d.edge", kMany, true, false, 0, &VecEdge<L, double, 3>);
    add("vec4d.edge", kMany, true, false, 0, &VecEdge<L, double, 4>);
    add("mat3f.edge", kMany, true, false, 0, &MatEdge<L, float, 3>);
    add("mat4f.edge", kMany, true, false, 0, &MatEdge<L, float, 4>);
    add("mat3d.edge", kMany, true, false, 0, &MatEdge<L, double, 3>);
    add("mat4d.edge", kMany, true, false, 0, &MatEdge<L, double, 4>);
    add("affinef.edge", kMany, true, true, 0, &AffineEdge<L, float>);
    add("affined.edge", kMany, true, true, 0, &AffineEdge<L, double>);
    add("vec3f.cross", kMany, true, false, 0, &Vec3Cross<L, float>);
    add("vec3d.cross", kMany, true, false, 0, &Vec3Cross<L, double>);
    add("mat4f.views", kMany, true, false, 0, &MatViews<L, float>);
    add("mat4d.views", kMany, true, false, 0, &MatViews<L, double>);
    add("mat3f.product", kMany, true, false, 0, &MatProduct<L, float, 3>);
    add("mat4f.product", kMany, true, false, 0, &MatProduct<L, float, 4>);
    add("mat3d.product", kMany, true, false, 0, &MatProduct<L, double, 3>);
    add("mat4d.product", kMany, true, false, 0, &MatProduct<L, double, 4>);
    add("matf.productShapes", kMany, true, false, 0, &MatProductShapes<L, float>);
    add("matd.productShapes", kMany, true, false, 0, &MatProductShapes<L, double>);
    add("mat3f.detInv", kMany, true, false, 0, &MatDetInv<L, float, 3>);
    add("mat4f.trs", kFew, false, false, 1e-4, &MatTrs<L, float>);
    add("mat3d.detInv", kMany, true, false, 0, &MatDetInv<L, double, 3>);
    add("mat4d.detInv", kFew, false, false, 1e-10, &MatDetInv<L, double, 4>);
    add("mat4d.trs", kFew, false, false, 1e-12, &MatTrs<L, double>);
    add("mat4f.singularModel", kSome, true, false, 0, &SingularModelInverse<L, float>);
    add("mat4d.singularModel", kSome, true, false, 0, &SingularModelInverse<L, double>);
    add("affine3f.zeroScale", kSome, true, true, 0, &ZeroScaleAffine<L, float>);
    add("affine3d.zeroScale", kSome, true, true, 0, &ZeroScaleAffine<L, double>);
    add("matf.mapArrays", kMany, true, false, 0, &MapAndArrays<L, float>);
    add("matd.mapArrays", kMany, true, false, 0, &MapAndArrays<L, double>);
    add("mat3f.predicates", kMany, true, false, 0, &MatPredicates<L, float, 3>);
    add("mat4f.predicates", kMany, true, false, 0, &MatPredicates<L, float, 4>);
    add("mat3d.predicates", kMany, true, false, 0, &MatPredicates<L, double, 3>);
    add("mat4d.predicates", kMany, true, false, 0, &MatPredicates<L, double, 4>);
    add("mat3f.colwise", kMany, true, false, 0, &MatColwise<L, float, 3>);
    add("mat4f.colwise", kMany, true, false, 0, &MatColwise<L, float, 4>);
    add("mat3d.colwise", kMany, true, false, 0, &MatColwise<L, double, 3>);
    add("mat4d.colwise", kMany, true, false, 0, &MatColwise<L, double, 4>);
    add("aa.f", kSome, true, true, 0, &RotationAA<L, float>);
    add("aa.d", kSome, true, true, 0, &RotationAA<L, double>);
    add("quat.f", kMany, true, false, 0, &QuatOps<L, float>);
    add("quat.d", kMany, true, false, 0, &QuatOps<L, double>);
    add("quatFromMatrix.f", kMany, true, true, 0, &QuatFromMatrix<L, float>);
    add("quatFromMatrix.d", kMany, true, true, 0, &QuatFromMatrix<L, double>);
    add("slerp.f", kSome, true, true, 0, &QuatSlerp<L, float>);
    add("slerp.d", kSome, true, true, 0, &QuatSlerp<L, double>);
    add("euler.f", kSome, true, true, 0, &EulerAngles<L, float>);
    add("euler.d", kSome, true, true, 0, &EulerAngles<L, double>);
    add("affineChain.f", kSome, true, true, 0, &AffineChain<L, float>);
    add("affineChain.d", kSome, true, true, 0, &AffineChain<L, double>);
    add("affineProducts.f", kSome, true, true, 0, &AffineProducts<L, float>);
    add("affineProducts.d", kSome, true, true, 0, &AffineProducts<L, double>);
    add("projective.d", kMany, true, false, 0, &ProjectiveOps<L>);
    add("camera.d", kSome, true, true, 0, &CameraMatrices<L>);
    add("lu.d", kMany, true, false, 0, &LuInverse<L>);
    return r;
}

// --- the library under test ---------------------------------------------------------

struct NewLib {
    template<class T, int R, int C>
    using Mat = wallpaper::linalg::Matrix<T, R, C>;
    template<class T>
    using Aff    = wallpaper::linalg::Transform<T, 3, wallpaper::linalg::Affine>;
    using Proj3d = wallpaper::linalg::Projective3d;
    template<class T>
    using AA = wallpaper::linalg::AngleAxis<T>;
    template<class T>
    using Quat = wallpaper::linalg::Quaternion<T>;
    template<class T>
    using Trans = wallpaper::linalg::Translation<T>;
    template<class M>
    using LU = wallpaper::linalg::FullPivLU<M>;
    template<class M>
    static auto CMap(const typename M::Scalar* p) {
        return wallpaper::linalg::Map<const M>(p);
    }
    template<class T>
    static auto Scale(T x, T y, T z) {
        return wallpaper::linalg::Scaling(x, y, z);
    }
    template<class T>
    static auto Scale(T x, T y) {
        return wallpaper::linalg::Scaling(x, y);
    }
    static double Radians(double a) { return wallpaper::linalg::Radians(a); }
    static auto   Ortho(double l, double r, double b, double t, double n, double f) {
        return wallpaper::linalg::Ortho(l, r, b, t, n, f);
    }
    static auto Perspective(double fov, double aspect, double n, double f) {
        return wallpaper::linalg::Perspective(fov, aspect, n, f);
    }
    template<class V>
    static auto LookAt(const V& eye, const V& center, const V& up) {
        return wallpaper::linalg::LookAt(eye, center, up);
    }
};

// --- hashing and comparison ---------------------------------------------------------

inline std::uint64_t Bits(double v) {
    if (v != v) return 0x7ff8000000000000ull; // every NaN is the same result
    std::uint64_t b;
    std::memcpy(&b, &v, sizeof b);
    return b;
}
inline std::uint64_t Hash(const Out& values) {
    std::uint64_t h = 0xcbf29ce484222325ull;
    for (double v : values) {
        std::uint64_t b = Bits(v);
        for (int i = 0; i < 8; ++i) {
            h = (h ^ (b & 0xffu)) * 0x100000001b3ull;
            b >>= 8;
        }
    }
    return h;
}

// Runs every case of `op`, appending the results and the number of values each
// produced, so two runs can be compared case by case.
template<class L>
void RunOp(const Op<L>& op, Out& out, std::vector<std::size_t>& boundaries,
           int casesOverride = -1) {
    const int cases = casesOverride > 0 ? casesOverride : op.spec.cases;
    for (int c = 0; c < cases; ++c) {
        Rng rng(SeedFor(op.spec.name, c));
        op.run(rng, out);
        boundaries.push_back(out.size());
    }
}

} // namespace linalg_cases
