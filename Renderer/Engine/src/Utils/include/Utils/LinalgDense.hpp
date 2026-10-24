// Fixed-size dense linear algebra for the scene engine: column-major vectors and
// matrices, plus the views, reductions and element-wise operators the engine uses.
//
// This is this project's own code, written from the mathematics and from the
// behaviour the engine's call sites rely on. It is not derived from any other
// linear-algebra library's source. The method names and conventions
// (`.x()`, `.norm()`, `.cast<T>()`, `.block<R, C>(i, j)`, `Zero()`, `isApprox`,
// `normalized()` of a zero vector being zero, ...) are the common spellings of
// small C++ linear-algebra libraries, so the engine's call sites read naturally.
// See Linalg.hpp for the umbrella header.
//
// Design:
//   * Every type is a standard-layout aggregate of its scalars: no padding, no
//     alignment beyond the scalar's, so `sizeof(Matrix<T, R, C>)` is R * C * sizeof(T)
//     and `data()` can be handed to a GPU upload or a C API as is.
//   * Operations return concrete values, never lazy expressions. There is no aliasing
//     hazard (`a = b * a` is safe) and `auto x = a + b;` holds a value.
//   * Views (`block`, `head`, `col`, `Map`, `Transform::linear`, ...) are writable
//     windows into their owner. A view taken from a temporary is a value, so
//     `(a * b).head<3>()` never dangles.
#pragma once

#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstddef>
#include <iterator>
#include <limits>
#include <ostream>
#include <sstream>
#include <string>
#include <type_traits>
#include <utility>

// Every expression below is evaluated exactly as written, each multiply and add
// rounded on its own. Letting the compiler fuse `a * b + c` would make the result depend
// on the compiler's flags and on how an expression happens to be parenthesised; the
// products that are fused on purpose use std::fma.
#pragma float_control(push)
#pragma clang fp contract(off)

// The small fixed-size operations are meant to be inlined into their callers, where the
// sizes are constants and the loops unroll away; a compiler that judged one of them too
// big to inline would turn a three-float product into a call.
#define LINALG_INLINE [[gnu::always_inline]] inline

namespace wallpaper::linalg
{

using Index = std::ptrdiff_t;

enum StorageOptions : int
{
    ColMajor = 0,
    RowMajor = 1,
};

inline constexpr double Pi = 3.14159265358979323846;

// The tolerance `isApprox`, `isZero` and `isIdentity` use when none is given.
template<class T>
constexpr T DummyPrecision() noexcept {
    if constexpr (std::is_same_v<T, float>)
        return 1e-5f;
    else if constexpr (std::is_same_v<T, double>)
        return 1e-12;
    else if constexpr (std::is_same_v<T, long double>)
        return static_cast<T>(1e-15L);
    else
        return T(0);
}

template<class D>
class DenseBase;
template<class T, int R, int C, int O = ColMajor>
class Matrix;
template<class T, int R, int C>
class Block;
template<class M>
class Map;
template<class T, int R, int C>
class Array;
template<class T, int R, int C>
class Colwise;

template<class D>
struct traits;

template<class T, int R, int C, int O>
struct traits<Matrix<T, R, C, O>> {
    using Scalar                 = T;
    static constexpr int  Rows   = R;
    static constexpr int  Cols   = C;
    static constexpr bool Owning = true;
};
template<class T, int R, int C>
struct traits<Block<T, R, C>> {
    using Scalar                 = std::remove_const_t<T>;
    static constexpr int  Rows   = R;
    static constexpr int  Cols   = C;
    static constexpr bool Owning = false;
};
template<class M>
struct traits<Map<M>>
    : traits<Block<
          std::conditional_t<std::is_const_v<M>, const typename M::Scalar, typename M::Scalar>,
          M::RowsAtCompileTime, M::ColsAtCompileTime>> {};

namespace detail
{
// An iterator over scalars a fixed stride apart: what `for (auto& v : column)` walks.
template<class T>
class StridedIterator {
public:
    using iterator_category = std::random_access_iterator_tag;
    using value_type        = std::remove_const_t<T>;
    using difference_type   = std::ptrdiff_t;
    using pointer           = T*;
    using reference         = T&;

    StridedIterator() = default;
    StridedIterator(T* p, std::ptrdiff_t stride) noexcept: p_(p), s_(stride) {}

    reference        operator*() const noexcept { return *p_; }
    pointer          operator->() const noexcept { return p_; }
    reference        operator[](difference_type n) const noexcept { return p_[n * s_]; }
    StridedIterator& operator++() noexcept {
        p_ += s_;
        return *this;
    }
    StridedIterator operator++(int) noexcept {
        auto copy = *this;
        p_ += s_;
        return copy;
    }
    StridedIterator& operator--() noexcept {
        p_ -= s_;
        return *this;
    }
    StridedIterator operator--(int) noexcept {
        auto copy = *this;
        p_ -= s_;
        return copy;
    }
    StridedIterator& operator+=(difference_type n) noexcept {
        p_ += n * s_;
        return *this;
    }
    StridedIterator& operator-=(difference_type n) noexcept {
        p_ -= n * s_;
        return *this;
    }
    friend StridedIterator operator+(StridedIterator it, difference_type n) noexcept {
        return it += n;
    }
    friend StridedIterator operator+(difference_type n, StridedIterator it) noexcept {
        return it += n;
    }
    friend StridedIterator operator-(StridedIterator it, difference_type n) noexcept {
        return it -= n;
    }
    friend difference_type operator-(const StridedIterator& a, const StridedIterator& b) noexcept {
        return (a.p_ - b.p_) / a.s_;
    }
    friend bool operator==(const StridedIterator& a, const StridedIterator& b) noexcept {
        return a.p_ == b.p_;
    }
    friend bool operator<(const StridedIterator& a, const StridedIterator& b) noexcept {
        return a.s_ >= 0 ? a.p_ < b.p_ : a.p_ > b.p_;
    }
    friend bool operator>(const StridedIterator& a, const StridedIterator& b) noexcept {
        return b < a;
    }
    friend bool operator<=(const StridedIterator& a, const StridedIterator& b) noexcept {
        return ! (b < a);
    }
    friend bool operator>=(const StridedIterator& a, const StridedIterator& b) noexcept {
        return ! (a < b);
    }

private:
    T*             p_ { nullptr };
    std::ptrdiff_t s_ { 1 };
};

// ---- the arithmetic order of the reductions and products --------------------------
//
// Floating-point sums depend on their order, and a fused multiply-add rounds once where
// a multiply and an add round twice. The order below is fixed (it never depends on a
// compiler flag) and was chosen so the engine's results are bit for bit those of the
// linear-algebra library this one replaced (tests/linalg_golden.inc pins them):
//   * a sum goes by packets of 2 (4 floats when the count allows) as described at Sum;
//     a squared norm is such a sum of squares, each square rounded;
//   * a dot product of 3 terms is (x0 y0 + x1 y1) with the last product fused in;
//   * the rows of a matrix product that fill whole 2-wide lanes (the first two of
//     three, all four of four) accumulate by a chain of fused multiply-adds over k,
//     and a leftover odd row is summed as a dot product of its own order.

// A fused multiply-add for the floating-point types; a plain one for integers.
template<class T>
LINALG_INLINE constexpr T Fma(T a, T b, T c) noexcept {
    if constexpr (std::is_floating_point_v<T>)
        return std::fma(a, b, c);
    else
        return static_cast<T>(a * b + c);
}

// One lane of a vectorised sum: the terms `x(first * P + lane)`, `x((first + 1) * P +
// lane)`, ... of `count` packets, added as a balanced tree whose left half is the
// largest power of two below `count`.
template<class T, Index P, Index First, Index Count, class F>
LINALG_INLINE constexpr T LaneTree(const F& x, Index lane) noexcept {
    if constexpr (Count == 1) {
        return x(First * P + lane);
    } else {
        constexpr Index Left = Count > 4 ? 4 : (Count > 2 ? 2 : 1);
        return LaneTree<T, P, First, Left>(x, lane) +
               LaneTree<T, P, First + Left, Count - Left>(x, lane);
    }
}

// Sum of `N` values; `x(k)` is the k-th. The values are taken as packets of P = 2 (or
// 4 when `N` is a multiple of 4 floats): each lane is summed over the packets, the
// lanes are added, then the values past the last whole packet are added one by one.
template<class T, Index N, class F>
LINALG_INLINE constexpr T Sum(const F& x) noexcept {
    if constexpr (N == 1) {
        return x(0);
    } else {
        constexpr Index P = (sizeof(T) == 4 && N % 4 == 0) ? 4 : 2;
        constexpr Index M = N / P;
        T               lanes[P];
        for (Index l = 0; l < P; ++l) lanes[l] = LaneTree<T, P, 0, M>(x, l);
        T s;
        if constexpr (P == 2)
            s = lanes[0] + lanes[1];
        else
            s = (lanes[0] + lanes[1]) + (lanes[2] + lanes[3]);
        for (Index k = M * P; k < N; ++k) s = s + x(k);
        return s;
    }
}

// Dot product of `N` pairs; `a(k)` and `b(k)` are the k-th of each.
template<class T, Index N, class FA, class FB>
LINALG_INLINE constexpr T Dot(const FA& a, const FB& b) noexcept {
    if constexpr (N == 3) {
        return Fma<T>(a(2), b(2), a(0) * b(0) + a(1) * b(1));
    } else {
        return Sum<T, N>([&](Index k) {
            return a(k) * b(k);
        });
    }
}

// The dot product that finishes a matrix-product row left out of the 2-wide lanes.
template<class T, Index N, class FA, class FB>
LINALG_INLINE constexpr T RowDot(const FA& a, const FB& b) noexcept {
    if constexpr (N == 3) {
        return (a(1) * b(1) + a(2) * b(2)) + a(0) * b(0);
    } else if constexpr (N == 4) {
        return (a(0) * b(0) + a(1) * b(1)) + (a(2) * b(2) + a(3) * b(3));
    } else {
        T s = a(0) * b(0);
        for (Index k = 1; k < N; ++k) s = s + a(k) * b(k);
        return s;
    }
}

template<class T>
LINALG_INLINE constexpr T Abs(T v) noexcept {
    if constexpr (std::is_unsigned_v<T>)
        return v;
    else if constexpr (std::is_floating_point_v<T>)
        return std::abs(v); // clears the sign of -0 too
    else
        return v < T(0) ? static_cast<T>(-v) : v;
}

// The length of the vector (x, y) scaled by its larger coordinate, so the squares can
// neither overflow nor underflow: p * sqrt(1 + (q / p)^2), the square summed in one
// fused step.
template<class T>
LINALG_INLINE T ScaledHypot(T x, T y) noexcept {
    const T ax = Abs(x), ay = Abs(y);
    const T p = ax < ay ? ay : ax;
    const T q = ax < ay ? ax : ay;
    if (p == T(0)) return p;
    const T r = q / p;
    return p * std::sqrt(Fma<T>(r, r, T(1)));
}
} // namespace detail

// Marks a scalar that `operator*` and friends accept next to a matrix: any arithmetic
// type, converted to the matrix's own scalar first.
template<class S>
concept ArithmeticScalar = std::is_arithmetic_v<S>;

template<class A, class B>
concept SameShape = std::is_same_v<typename traits<A>::Scalar, typename traits<B>::Scalar> &&
                    traits<A>::Rows == traits<B>::Rows && traits<A>::Cols == traits<B>::Cols;

template<class D>
class CommaInitializer;

template<class D>
class DenseBase {
public:
    using Scalar                                = typename traits<D>::Scalar;
    using RealScalar                            = Scalar;
    static constexpr int  RowsAtCompileTime     = traits<D>::Rows;
    static constexpr int  ColsAtCompileTime     = traits<D>::Cols;
    static constexpr int  SizeAtCompileTime     = RowsAtCompileTime * ColsAtCompileTime;
    static constexpr bool IsVectorAtCompileTime = RowsAtCompileTime == 1 || ColsAtCompileTime == 1;
    using PlainObject = Matrix<Scalar, RowsAtCompileTime, ColsAtCompileTime>;

    D&       derived() noexcept { return static_cast<D&>(*this); }
    const D& derived() const noexcept { return static_cast<const D&>(*this); }

    static constexpr Index rows() noexcept { return RowsAtCompileTime; }
    static constexpr Index cols() noexcept { return ColsAtCompileTime; }
    static constexpr Index size() noexcept { return SizeAtCompileTime; }

    // --- element access -------------------------------------------------------------
    const Scalar&  coeff(Index i, Index j) const noexcept { return derived().elem(i, j); }
    decltype(auto) coeffRef(Index i, Index j) noexcept { return derived().elem(i, j); }
    const Scalar&  operator()(Index i, Index j) const noexcept { return derived().elem(i, j); }
    decltype(auto) operator()(Index i, Index j) noexcept { return derived().elem(i, j); }

    const Scalar& coeff(Index i) const noexcept
        requires IsVectorAtCompileTime
    {
        return ColsAtCompileTime == 1 ? derived().elem(i, 0) : derived().elem(0, i);
    }
    decltype(auto) coeffRef(Index i) noexcept
        requires IsVectorAtCompileTime
    {
        return ColsAtCompileTime == 1 ? derived().elem(i, 0) : derived().elem(0, i);
    }
    const Scalar& operator()(Index i) const noexcept
        requires IsVectorAtCompileTime
    {
        return coeff(i);
    }
    decltype(auto) operator()(Index i) noexcept
        requires IsVectorAtCompileTime
    {
        return coeffRef(i);
    }
    const Scalar& operator[](Index i) const noexcept
        requires IsVectorAtCompileTime
    {
        return coeff(i);
    }
    decltype(auto) operator[](Index i) noexcept
        requires IsVectorAtCompileTime
    {
        return coeffRef(i);
    }

    const Scalar& x() const noexcept
        requires(IsVectorAtCompileTime && SizeAtCompileTime >= 1)
    {
        return coeff(0);
    }
    const Scalar& y() const noexcept
        requires(IsVectorAtCompileTime && SizeAtCompileTime >= 2)
    {
        return coeff(1);
    }
    const Scalar& z() const noexcept
        requires(IsVectorAtCompileTime && SizeAtCompileTime >= 3)
    {
        return coeff(2);
    }
    const Scalar& w() const noexcept
        requires(IsVectorAtCompileTime && SizeAtCompileTime >= 4)
    {
        return coeff(3);
    }
    decltype(auto) x() noexcept
        requires(IsVectorAtCompileTime && SizeAtCompileTime >= 1)
    {
        return coeffRef(0);
    }
    decltype(auto) y() noexcept
        requires(IsVectorAtCompileTime && SizeAtCompileTime >= 2)
    {
        return coeffRef(1);
    }
    decltype(auto) z() noexcept
        requires(IsVectorAtCompileTime && SizeAtCompileTime >= 3)
    {
        return coeffRef(2);
    }
    decltype(auto) w() noexcept
        requires(IsVectorAtCompileTime && SizeAtCompileTime >= 4)
    {
        return coeffRef(3);
    }

    // --- conversions ---------------------------------------------------------------
    PlainObject eval() const { return PlainObject(derived()); }

    template<class U>
    Matrix<U, RowsAtCompileTime, ColsAtCompileTime> cast() const noexcept {
        Matrix<U, RowsAtCompileTime, ColsAtCompileTime> out;
        for (Index j = 0; j < cols(); ++j)
            for (Index i = 0; i < rows(); ++i) out.elem(i, j) = static_cast<U>(coeff(i, j));
        return out;
    }

    Matrix<Scalar, ColsAtCompileTime, RowsAtCompileTime> transpose() const noexcept {
        Matrix<Scalar, ColsAtCompileTime, RowsAtCompileTime> out;
        for (Index j = 0; j < cols(); ++j)
            for (Index i = 0; i < rows(); ++i) out.elem(j, i) = coeff(i, j);
        return out;
    }

    Array<Scalar, RowsAtCompileTime, ColsAtCompileTime> array() const noexcept;

    // This column vector with a 1 appended.
    Matrix<Scalar, SizeAtCompileTime + 1, 1> homogeneous() const noexcept
        requires(ColsAtCompileTime == 1)
    {
        Matrix<Scalar, SizeAtCompileTime + 1, 1> out;
        for (Index i = 0; i < size(); ++i) out.elem(i, 0) = coeff(i);
        out.elem(size(), 0) = Scalar(1);
        return out;
    }

    // The diagonal matrix with this vector on its diagonal.
    Matrix<Scalar, SizeAtCompileTime, SizeAtCompileTime> asDiagonal() const noexcept
        requires IsVectorAtCompileTime
    {
        Matrix<Scalar, SizeAtCompileTime, SizeAtCompileTime> out =
            Matrix<Scalar, SizeAtCompileTime, SizeAtCompileTime>::Zero();
        for (Index i = 0; i < size(); ++i) out.elem(i, i) = coeff(i);
        return out;
    }

    // --- reductions ----------------------------------------------------------------
    Scalar sum() const noexcept {
        return detail::Sum<Scalar, SizeAtCompileTime>([&](Index k) {
            return linearCoeff(k);
        });
    }
    Scalar squaredNorm() const noexcept {
        return detail::Sum<Scalar, SizeAtCompileTime>([&](Index k) {
            const Scalar v = linearCoeff(k);
            return v * v;
        });
    }
    RealScalar norm() const noexcept
        requires std::is_floating_point_v<Scalar>
    {
        return std::sqrt(squaredNorm());
    }

    template<class O>
        requires SameShape<D, O>
    Scalar dot(const DenseBase<O>& other) const noexcept {
        return detail::Dot<Scalar, SizeAtCompileTime>(
            [&](Index k) {
                return linearCoeff(k);
            },
            [&](Index k) {
                return other.linearCoeff(k);
            });
    }

    Scalar maxCoeff() const noexcept {
        Scalar best = linearCoeff(0);
        for (Index k = 1; k < size(); ++k) {
            const Scalar v = linearCoeff(k);
            if (best < v) best = v;
        }
        return best;
    }
    Scalar minCoeff() const noexcept {
        Scalar best = linearCoeff(0);
        for (Index k = 1; k < size(); ++k) {
            const Scalar v = linearCoeff(k);
            if (v < best) best = v;
        }
        return best;
    }

    bool allFinite() const noexcept {
        if constexpr (std::is_floating_point_v<Scalar>) {
            for (Index k = 0; k < size(); ++k)
                if (! std::isfinite(linearCoeff(k))) return false;
        }
        return true;
    }

    // The relative comparison: ||a - b|| <= prec * min(||a||, ||b||), evaluated on the
    // squared norms. Against a zero vector, or with prec 0, only an exact match passes.
    template<class O>
        requires SameShape<D, O>
    bool isApprox(const DenseBase<O>& other,
                  RealScalar          prec = DummyPrecision<Scalar>()) const noexcept {
        const Scalar a    = squaredNorm();
        const Scalar b    = other.squaredNorm();
        const Scalar diff = detail::Sum<Scalar, SizeAtCompileTime>([&](Index k) {
            const Scalar d = linearCoeff(k) - other.linearCoeff(k);
            return d * d;
        });
        return diff <= prec * prec * std::min(a, b);
    }
    // True when every coefficient is within `prec` of zero.
    bool isZero(RealScalar prec = DummyPrecision<Scalar>()) const noexcept {
        for (Index k = 0; k < size(); ++k)
            if (! (detail::Abs(linearCoeff(k)) <= prec)) return false;
        return true;
    }
    // True when every coefficient is approximately `value`, each compared to it on its
    // own: |x - value| <= prec * min(|x|, |value|).
    bool isApproxToConstant(const Scalar& value,
                            RealScalar    prec = DummyPrecision<Scalar>()) const noexcept {
        for (Index k = 0; k < size(); ++k) {
            const Scalar x = linearCoeff(k);
            if (! (detail::Abs(x - value) <= std::min(detail::Abs(x), detail::Abs(value)) * prec))
                return false;
        }
        return true;
    }
    bool isOnes(RealScalar prec = DummyPrecision<Scalar>()) const noexcept {
        return isApproxToConstant(Scalar(1), prec);
    }
    // True when the diagonal is within `prec` of 1 and the rest within `prec` of 0.
    bool isIdentity(RealScalar prec = DummyPrecision<Scalar>()) const noexcept {
        for (Index j = 0; j < cols(); ++j) {
            for (Index i = 0; i < rows(); ++i) {
                const Scalar v = coeff(i, j);
                if (i == j) {
                    if (! (detail::Abs(v - Scalar(1)) <=
                           std::min(detail::Abs(v), Scalar(1)) * prec))
                        return false;
                } else if (! (detail::Abs(v) <= prec)) {
                    return false;
                }
            }
        }
        return true;
    }

    // --- element-wise helpers -------------------------------------------------------
    template<class O>
        requires SameShape<D, O>
    PlainObject cwiseProduct(const DenseBase<O>& other) const noexcept {
        PlainObject out;
        for (Index j = 0; j < cols(); ++j)
            for (Index i = 0; i < rows(); ++i) out.elem(i, j) = coeff(i, j) * other.coeff(i, j);
        return out;
    }
    template<class O>
        requires SameShape<D, O>
    PlainObject cwiseMin(const DenseBase<O>& other) const noexcept {
        PlainObject out;
        for (Index j = 0; j < cols(); ++j) {
            for (Index i = 0; i < rows(); ++i) {
                const Scalar a = coeff(i, j), b = other.coeff(i, j);
                out.elem(i, j) = b < a ? b : a;
            }
        }
        return out;
    }
    template<class O>
        requires SameShape<D, O>
    PlainObject cwiseMax(const DenseBase<O>& other) const noexcept {
        PlainObject out;
        for (Index j = 0; j < cols(); ++j) {
            for (Index i = 0; i < rows(); ++i) {
                const Scalar a = coeff(i, j), b = other.coeff(i, j);
                out.elem(i, j) = a < b ? b : a;
            }
        }
        return out;
    }
    PlainObject cwiseAbs() const noexcept {
        PlainObject out;
        for (Index j = 0; j < cols(); ++j)
            for (Index i = 0; i < rows(); ++i) out.elem(i, j) = detail::Abs(coeff(i, j));
        return out;
    }

    // The unit vector in this direction; the vector itself when its squared norm is
    // not positive (so a zero vector stays zero instead of becoming NaN).
    PlainObject normalized() const noexcept
        requires std::is_floating_point_v<Scalar>
    {
        const Scalar n = squaredNorm();
        if (n > Scalar(0)) return PlainObject(derived() / std::sqrt(n));
        return PlainObject(derived());
    }
    void normalize() noexcept
        requires std::is_floating_point_v<Scalar>
    {
        const Scalar n = squaredNorm();
        if (n > Scalar(0)) derived() /= std::sqrt(n);
    }

    template<class O>
        requires(SameShape<D, O> && SizeAtCompileTime == 3 && IsVectorAtCompileTime)
    PlainObject cross(const DenseBase<O>& other) const noexcept {
        const Scalar ax = coeff(0), ay = coeff(1), az = coeff(2);
        const Scalar bx = other.coeff(0), by = other.coeff(1), bz = other.coeff(2);
        PlainObject  out;
        out.coeffRef(0) = detail::Fma<Scalar>(ay, bz, -(az * by));
        out.coeffRef(1) = detail::Fma<Scalar>(az, bx, -(ax * bz));
        out.coeffRef(2) = detail::Fma<Scalar>(ax, by, -(ay * bx));
        return out;
    }

    // --- square matrices ------------------------------------------------------------
    Scalar determinant() const noexcept
        requires(RowsAtCompileTime == ColsAtCompileTime && RowsAtCompileTime >= 1 &&
                 RowsAtCompileTime <= 4)
    {
        const auto m = [&](Index i, Index j) {
            return coeff(i, j);
        };
        if constexpr (RowsAtCompileTime == 1) {
            return m(0, 0);
        } else if constexpr (RowsAtCompileTime == 2) {
            return m(0, 0) * m(1, 1) - m(0, 1) * m(1, 0);
        } else if constexpr (RowsAtCompileTime == 3) {
            // Expansion along the first row over its 2 x 2 minors, each minor rounded once.
            const Scalar d0 = detail::Fma<Scalar>(m(1, 1), m(2, 2), -(m(1, 2) * m(2, 1)));
            const Scalar d1 = detail::Fma<Scalar>(m(1, 0), m(2, 2), -(m(1, 2) * m(2, 0)));
            const Scalar d2 = detail::Fma<Scalar>(m(1, 0), m(2, 1), -(m(1, 1) * m(2, 0)));
            return (m(0, 0) * d0 + (-m(0, 1)) * d1) + m(0, 2) * d2;
        } else {
            // Laplace expansion along the top two rows over their 2 x 2 minors.
            const Scalar s0 = m(0, 0) * m(1, 1) - m(1, 0) * m(0, 1);
            const Scalar s1 = m(0, 0) * m(1, 2) - m(1, 0) * m(0, 2);
            const Scalar s2 = m(0, 0) * m(1, 3) - m(1, 0) * m(0, 3);
            const Scalar s3 = m(0, 1) * m(1, 2) - m(1, 1) * m(0, 2);
            const Scalar s4 = m(0, 1) * m(1, 3) - m(1, 1) * m(0, 3);
            const Scalar s5 = m(0, 2) * m(1, 3) - m(1, 2) * m(0, 3);
            const Scalar c5 = m(2, 2) * m(3, 3) - m(3, 2) * m(2, 3);
            const Scalar c4 = m(2, 1) * m(3, 3) - m(3, 1) * m(2, 3);
            const Scalar c3 = m(2, 1) * m(3, 2) - m(3, 1) * m(2, 2);
            const Scalar c2 = m(2, 0) * m(3, 3) - m(3, 0) * m(2, 3);
            const Scalar c1 = m(2, 0) * m(3, 2) - m(3, 0) * m(2, 2);
            const Scalar c0 = m(2, 0) * m(3, 1) - m(3, 0) * m(2, 1);
            return s0 * c5 - s1 * c4 + s2 * c3 + s3 * c2 - s4 * c1 + s5 * c0;
        }
    }

    // The inverse by cofactors. A singular matrix gives non-finite entries, as
    // dividing by its zero determinant does; callers that care test `determinant()`
    // or use `FullPivLU` first.
    //
    // How far this follows the library it replaced (measured against it, 200,000
    // matrices per kind): 2 x 2 and 3 x 3 inverses and determinants, singular ones
    // included, return the same bits; so do 4 x 4 inverses of matrices whose
    // determinant is exactly zero in both, such as a model matrix scaled to nothing
    // with small-integer or exactly representable entries (pinned by the
    // `mat4d.singularModel` golden list). The 4 x 4 cofactor and determinant
    // arithmetic is NOT in the replaced library's order: for ordinary matrices the
    // two agree to about 1e-12 relative (1e-6 in float), and for a singular matrix
    // whose entries carry rounding noise, one that is exactly singular only in exact
    // arithmetic (a rotated layer scaled to nothing on one axis, a matrix with a
    // duplicated or zero row), the determinants differ in the last bits, so one side
    // may compute exactly zero (infinities and NaNs) where the other computes noise
    // (about 1e16 in size): 17 % of rotated zero-scale model matrices (51,203 of
    // 300,000) invert to different bits. For such a transform, `Transform::inverse`
    // and `FullPivLU`'s verdict are bit-identical to the replaced library's (pinned
    // by `affine3d.zeroScale`); the engine's `Matrix4d::inverse()` calls (shader
    // inverse uniforms, camera view, mouse-to-local) get the noise version.
    PlainObject inverse() const noexcept
        requires(RowsAtCompileTime == ColsAtCompileTime && RowsAtCompileTime >= 1 &&
                 RowsAtCompileTime <= 4)
    {
        const auto m = [&](Index i, Index j) {
            return coeff(i, j);
        };
        PlainObject out;
        if constexpr (RowsAtCompileTime == 1) {
            out.elem(0, 0) = Scalar(1) / m(0, 0);
        } else if constexpr (RowsAtCompileTime == 2) {
            const Scalar inv = Scalar(1) / determinant();
            out.elem(0, 0)   = m(1, 1) * inv;
            out.elem(0, 1)   = -m(0, 1) * inv;
            out.elem(1, 0)   = -m(1, 0) * inv;
            out.elem(1, 1)   = m(0, 0) * inv;
        } else if constexpr (RowsAtCompileTime == 3) {
            // The cofactor of (i, j) in cyclic index order (each rounded once), the
            // determinant by expansion down the first column, and the transposed
            // cofactors scaled by its reciprocal.
            const auto cofactor = [&](Index i, Index j) {
                const Index i1 = (i + 1) % 3, i2 = (i + 2) % 3, j1 = (j + 1) % 3, j2 = (j + 2) % 3;
                return detail::Fma<Scalar>(m(i1, j1), m(i2, j2), -(m(i1, j2) * m(i2, j1)));
            };
            Scalar c[3][3];
            for (Index i = 0; i < 3; ++i)
                for (Index j = 0; j < 3; ++j) c[i][j] = cofactor(i, j);
            const Scalar det = (m(0, 0) * c[0][0] + m(1, 0) * c[1][0]) + m(2, 0) * c[2][0];
            const Scalar inv = Scalar(1) / det;
            for (Index i = 0; i < 3; ++i)
                for (Index j = 0; j < 3; ++j) out.elem(j, i) = c[i][j] * inv;
        } else {
            // Adjugate from the 2 x 2 minors of the top two and bottom two rows.
            const Scalar s0  = m(0, 0) * m(1, 1) - m(1, 0) * m(0, 1);
            const Scalar s1  = m(0, 0) * m(1, 2) - m(1, 0) * m(0, 2);
            const Scalar s2  = m(0, 0) * m(1, 3) - m(1, 0) * m(0, 3);
            const Scalar s3  = m(0, 1) * m(1, 2) - m(1, 1) * m(0, 2);
            const Scalar s4  = m(0, 1) * m(1, 3) - m(1, 1) * m(0, 3);
            const Scalar s5  = m(0, 2) * m(1, 3) - m(1, 2) * m(0, 3);
            const Scalar c5  = m(2, 2) * m(3, 3) - m(3, 2) * m(2, 3);
            const Scalar c4  = m(2, 1) * m(3, 3) - m(3, 1) * m(2, 3);
            const Scalar c3  = m(2, 1) * m(3, 2) - m(3, 1) * m(2, 2);
            const Scalar c2  = m(2, 0) * m(3, 3) - m(3, 0) * m(2, 3);
            const Scalar c1  = m(2, 0) * m(3, 2) - m(3, 0) * m(2, 2);
            const Scalar c0  = m(2, 0) * m(3, 1) - m(3, 0) * m(2, 1);
            const Scalar det = s0 * c5 - s1 * c4 + s2 * c3 + s3 * c2 - s4 * c1 + s5 * c0;
            const Scalar inv = Scalar(1) / det;
            out.elem(0, 0)   = (m(1, 1) * c5 - m(1, 2) * c4 + m(1, 3) * c3) * inv;
            out.elem(0, 1)   = (-m(0, 1) * c5 + m(0, 2) * c4 - m(0, 3) * c3) * inv;
            out.elem(0, 2)   = (m(3, 1) * s5 - m(3, 2) * s4 + m(3, 3) * s3) * inv;
            out.elem(0, 3)   = (-m(2, 1) * s5 + m(2, 2) * s4 - m(2, 3) * s3) * inv;
            out.elem(1, 0)   = (-m(1, 0) * c5 + m(1, 2) * c2 - m(1, 3) * c1) * inv;
            out.elem(1, 1)   = (m(0, 0) * c5 - m(0, 2) * c2 + m(0, 3) * c1) * inv;
            out.elem(1, 2)   = (-m(3, 0) * s5 + m(3, 2) * s2 - m(3, 3) * s1) * inv;
            out.elem(1, 3)   = (m(2, 0) * s5 - m(2, 2) * s2 + m(2, 3) * s1) * inv;
            out.elem(2, 0)   = (m(1, 0) * c4 - m(1, 1) * c2 + m(1, 3) * c0) * inv;
            out.elem(2, 1)   = (-m(0, 0) * c4 + m(0, 1) * c2 - m(0, 3) * c0) * inv;
            out.elem(2, 2)   = (m(3, 0) * s4 - m(3, 1) * s2 + m(3, 3) * s0) * inv;
            out.elem(2, 3)   = (-m(2, 0) * s4 + m(2, 1) * s2 - m(2, 3) * s0) * inv;
            out.elem(3, 0)   = (-m(1, 0) * c3 + m(1, 1) * c1 - m(1, 2) * c0) * inv;
            out.elem(3, 1)   = (m(0, 0) * c3 - m(0, 1) * c1 + m(0, 2) * c0) * inv;
            out.elem(3, 2)   = (-m(3, 0) * s3 + m(3, 1) * s1 - m(3, 2) * s0) * inv;
            out.elem(3, 3)   = (m(2, 0) * s3 - m(2, 1) * s1 + m(2, 2) * s0) * inv;
        }
        return out;
    }

    // The Euler angles (a0, a1, a2) of a rotation matrix for the axis order
    // R = R_a0(angle0) * R_a1(angle1) * R_a2(angle2): each axis argument is 0, 1 or 2,
    // all three different (the Tait-Bryan orders, e.g. (2, 1, 0) for Z then Y then X).
    // The first angle is returned in [0, pi], the others in [-pi, pi].
    //
    // The two parities of axis order are one computation in a mirrored frame whose
    // angles are negated at the end: a cyclic order (X, Y, Z) is the mirror image of
    // an anticyclic one. Working in that frame keeps the result, including the sign of
    // an exact zero and which of the two equivalent angle triples is picked, the same
    // for every order.
    Matrix<Scalar, 3, 1> eulerAngles(int a0, int a1, int a2) const noexcept
        requires(RowsAtCompileTime == 3 && ColsAtCompileTime == 3 &&
                 std::is_floating_point_v<Scalar>)
    {
        assert(a0 != a1 && a1 != a2 && a0 != a2 && "only three different axes are supported");
        const Index i = a0, j = a1, k = a2;
        const bool  odd = (i + 1) % 3 != j;
        const auto  m   = [&](Index r, Index c) {
            return coeff(r, c);
        };
        const Scalar pi = static_cast<Scalar>(Pi);

        // Column k gives tan(a) = R(j,k) / R(k,k), and the magnitude of cos(b) comes
        // from row i. The other solution of the first two angles (a -+ pi, pi - b) is
        // taken when a is on the wrong side of zero, which puts the final a in [0, pi].
        Scalar       alpha   = std::atan2(m(j, k), m(k, k));
        const Scalar cosBeta = detail::ScaledHypot(m(i, i), m(i, j));
        Scalar       beta;
        if ((odd && alpha < Scalar(0)) || (! odd && alpha > Scalar(0))) {
            alpha += alpha > Scalar(0) ? -pi : pi;
            beta = std::atan2(-m(i, k), -cosBeta);
        } else {
            beta = std::atan2(-m(i, k), cosBeta);
        }
        // With a known, row j of R_i(-a) R is row j of R_j(b) R_k(c), which does not
        // depend on b and holds sin(c) and cos(c).
        const Scalar s1    = std::sin(alpha);
        const Scalar c1    = std::cos(alpha);
        Scalar       gamma = std::atan2(detail::Fma<Scalar>(s1, m(k, i), -(c1 * m(j, i))),
                                  detail::Fma<Scalar>(c1, m(j, j), -(s1 * m(k, j))));
        if (! odd) return Matrix<Scalar, 3, 1>(-alpha, -beta, -gamma);
        return Matrix<Scalar, 3, 1>(alpha, beta, gamma);
    }

    // --- views -----------------------------------------------------------------------
    template<int BR, int BC>
    auto block(Index i, Index j) & noexcept {
        static_assert(BR <= RowsAtCompileTime && BC <= ColsAtCompileTime);
        return derived().template view<BR, BC>(i, j);
    }
    template<int BR, int BC>
    auto block(Index i, Index j) const& noexcept {
        static_assert(BR <= RowsAtCompileTime && BC <= ColsAtCompileTime);
        return derived().template cview<BR, BC>(i, j);
    }
    // A block of a temporary matrix is a value; a block of a temporary view still
    // writes through to what the view looks at.
    template<int BR, int BC>
    auto block(Index i, Index j) && noexcept {
        static_assert(BR <= RowsAtCompileTime && BC <= ColsAtCompileTime);
        if constexpr (traits<D>::Owning) {
            return Matrix<Scalar, BR, BC>(derived().template cview<BR, BC>(i, j));
        } else {
            return derived().template view<BR, BC>(i, j);
        }
    }

    template<int N>
    auto head() & noexcept {
        return headOf<N>(*this);
    }
    template<int N>
    auto head() const& noexcept {
        return headOf<N>(std::as_const(*this));
    }
    template<int N>
    auto head() && noexcept {
        return headOf<N>(std::move(*this));
    }
    template<int BR, int BC>
    auto topLeftCorner() & noexcept {
        return block<BR, BC>(0, 0);
    }
    template<int BR, int BC>
    auto topLeftCorner() const& noexcept {
        return std::as_const(*this).template block<BR, BC>(0, 0);
    }
    template<int BR, int BC>
    auto topLeftCorner() && noexcept {
        return std::move(*this).template block<BR, BC>(0, 0);
    }
    template<int BR, int BC>
    auto topRightCorner() & noexcept {
        return block<BR, BC>(0, ColsAtCompileTime - BC);
    }
    template<int BR, int BC>
    auto topRightCorner() const& noexcept {
        return block<BR, BC>(0, ColsAtCompileTime - BC);
    }
    template<int BR, int BC>
    auto topRightCorner() && noexcept {
        return std::move(*this).template block<BR, BC>(0, ColsAtCompileTime - BC);
    }
    auto col(Index j) & noexcept { return block<RowsAtCompileTime, 1>(0, j); }
    auto col(Index j) const& noexcept { return block<RowsAtCompileTime, 1>(0, j); }
    auto col(Index j) && noexcept {
        return std::move(*this).template block<RowsAtCompileTime, 1>(0, j);
    }
    auto row(Index i) & noexcept { return block<1, ColsAtCompileTime>(i, 0); }
    auto row(Index i) const& noexcept { return block<1, ColsAtCompileTime>(i, 0); }
    auto row(Index i) && noexcept {
        return std::move(*this).template block<1, ColsAtCompileTime>(i, 0);
    }

    // Column-wise iteration and reductions: `for (auto col : m.colwise())` and
    // `m.colwise().norm()`.
    Colwise<Scalar, RowsAtCompileTime, ColsAtCompileTime> colwise() & noexcept {
        return Colwise<Scalar, RowsAtCompileTime, ColsAtCompileTime>(
            derived().template view<RowsAtCompileTime, ColsAtCompileTime>(0, 0));
    }
    Colwise<const Scalar, RowsAtCompileTime, ColsAtCompileTime> colwise() const& noexcept {
        return Colwise<const Scalar, RowsAtCompileTime, ColsAtCompileTime>(
            derived().template cview<RowsAtCompileTime, ColsAtCompileTime>(0, 0));
    }

    // --- initialisation ---------------------------------------------------------------
    CommaInitializer<D> operator<<(const Scalar& first) noexcept;

    // Scalar at the `k`-th place in column-major order, whatever the storage order.
    const Scalar& linearCoeff(Index k) const noexcept {
        return derived().elem(k % rows(), k / rows());
    }

protected:
    DenseBase() = default;

private:
    template<int N, class Self>
    static auto headOf(Self&& self) noexcept {
        static_assert(IsVectorAtCompileTime && N <= SizeAtCompileTime);
        if constexpr (ColsAtCompileTime == 1)
            return std::forward<Self>(self).template block<N, 1>(0, 0);
        else
            return std::forward<Self>(self).template block<1, N>(0, 0);
    }
};

// Operations that change a matrix in place. Kept out of DenseBase so a read-only view
// cannot even name them.
template<class D>
class WritableDense : public DenseBase<D> {
public:
    using Base   = DenseBase<D>;
    using Scalar = typename Base::Scalar;
    using Base::cols;
    using Base::rows;
    using Base::size;

    template<class O>
        requires SameShape<D, O>
    D& operator+=(const DenseBase<O>& other) noexcept {
        for (Index j = 0; j < cols(); ++j)
            for (Index i = 0; i < rows(); ++i) this->derived().elem(i, j) += other.coeff(i, j);
        return this->derived();
    }
    template<class O>
        requires SameShape<D, O>
    D& operator-=(const DenseBase<O>& other) noexcept {
        for (Index j = 0; j < cols(); ++j)
            for (Index i = 0; i < rows(); ++i) this->derived().elem(i, j) -= other.coeff(i, j);
        return this->derived();
    }
    template<ArithmeticScalar S>
    D& operator*=(S s) noexcept {
        const Scalar t = static_cast<Scalar>(s);
        for (Index j = 0; j < cols(); ++j)
            for (Index i = 0; i < rows(); ++i) this->derived().elem(i, j) *= t;
        return this->derived();
    }
    template<ArithmeticScalar S>
    D& operator/=(S s) noexcept {
        const Scalar t = static_cast<Scalar>(s);
        for (Index j = 0; j < cols(); ++j)
            for (Index i = 0; i < rows(); ++i) this->derived().elem(i, j) /= t;
        return this->derived();
    }

    D& fill(const Scalar& v) noexcept {
        for (Index j = 0; j < cols(); ++j)
            for (Index i = 0; i < rows(); ++i) this->derived().elem(i, j) = v;
        return this->derived();
    }
    D& setConstant(const Scalar& v) noexcept { return fill(v); }
    D& setZero() noexcept { return fill(Scalar(0)); }

    // Copies `other` in, reading all of it first, so overlapping views are safe.
    template<class O>
    void assignFrom(const DenseBase<O>& other) noexcept {
        if constexpr (traits<O>::Owning) {
            for (Index j = 0; j < cols(); ++j)
                for (Index i = 0; i < rows(); ++i) this->derived().elem(i, j) = other.coeff(i, j);
        } else {
            const typename DenseBase<O>::PlainObject copy(other.derived());
            for (Index j = 0; j < cols(); ++j)
                for (Index i = 0; i < rows(); ++i) this->derived().elem(i, j) = copy.elem(i, j);
        }
    }

    auto begin() noexcept
        requires Base::IsVectorAtCompileTime
    {
        return this->derived().template makeIterator<false>();
    }
    auto end() noexcept
        requires Base::IsVectorAtCompileTime
    {
        return this->derived().template makeIterator<true>();
    }

protected:
    WritableDense() = default;
};

// ---------------------------------------------------------------------------------
// Matrix: owning, fixed-size, standard layout.

template<class T, int R, int C, int O>
class Matrix : public WritableDense<Matrix<T, R, C, O>> {
    static_assert(R > 0 && C > 0, "fixed-size matrices only");
    static_assert(std::is_arithmetic_v<T>);
    using Base = WritableDense<Matrix<T, R, C, O>>;

public:
    using Scalar                                = T;
    using RealScalar                            = T;
    static constexpr int RowsAtCompileTime      = R;
    static constexpr int ColsAtCompileTime      = C;
    static constexpr int SizeAtCompileTime      = R * C;
    static constexpr int Options                = O;
    using value_type                            = T;
    using iterator                              = T*;
    using const_iterator                        = const T*;
    static constexpr bool IsVectorAtCompileTime = R == 1 || C == 1;

    // Left uninitialised, as a plain array is; `Matrix{}` zero-initialises.
    Matrix() = default;

    Matrix(const T& x, const T& y, const T& z) noexcept
        requires(R* C == 3 && IsVectorAtCompileTime)
    {
        d_[0] = x;
        d_[1] = y;
        d_[2] = z;
    }
    Matrix(const T& x, const T& y, const T& z, const T& w) noexcept
        requires(R* C == 4 && IsVectorAtCompileTime)
    {
        d_[0] = x;
        d_[1] = y;
        d_[2] = z;
        d_[3] = w;
    }
    template<ArithmeticScalar A, ArithmeticScalar B>
    Matrix(const A& x, const B& y) noexcept
        requires(R* C == 2 && IsVectorAtCompileTime)
    {
        d_[0] = static_cast<T>(x);
        d_[1] = static_cast<T>(y);
    }
    // Copies R * C scalars from `p`, in storage order (column by column).
    explicit Matrix(const T* p) noexcept {
        for (int k = 0; k < R * C; ++k) d_[k] = p[k];
    }

    // From any matrix of the same shape and scalar (a view, another storage order);
    // a vector also takes the transposed shape, so a row vector fills a column vector.
    template<class D2>
        requires(std::is_same_v<typename traits<D2>::Scalar, T> &&
                 ((traits<D2>::Rows == R && traits<D2>::Cols == C) ||
                  (IsVectorAtCompileTime && traits<D2>::Rows == C && traits<D2>::Cols == R)))
    Matrix(const DenseBase<D2>& other) noexcept { // NOLINT: implicit like the views it accepts
        assignTo(other);
    }

    template<class D2>
        requires(std::is_same_v<typename traits<D2>::Scalar, T> &&
                 ((traits<D2>::Rows == R && traits<D2>::Cols == C) ||
                  (IsVectorAtCompileTime && traits<D2>::Rows == C && traits<D2>::Cols == R)))
    Matrix& operator=(const DenseBase<D2>& other) noexcept {
        if constexpr (traits<D2>::Owning) {
            assignTo(other);
        } else {
            const Matrix<T, traits<D2>::Rows, traits<D2>::Cols> copy(other.derived());
            assignTo(copy);
        }
        return *this;
    }

    static Matrix Zero() noexcept { return Constant(T(0)); }
    static Matrix Ones() noexcept { return Constant(T(1)); }
    static Matrix Constant(const T& v) noexcept {
        Matrix m;
        for (int k = 0; k < R * C; ++k) m.d_[k] = v;
        return m;
    }
    static Matrix Identity() noexcept {
        Matrix m;
        for (Index j = 0; j < C; ++j)
            for (Index i = 0; i < R; ++i) m.elem(i, j) = i == j ? T(1) : T(0);
        return m;
    }
    static Matrix UnitX() noexcept
        requires(IsVectorAtCompileTime && R * C >= 1)
    {
        return Unit(0);
    }
    static Matrix UnitY() noexcept
        requires(IsVectorAtCompileTime && R * C >= 2)
    {
        return Unit(1);
    }
    static Matrix UnitZ() noexcept
        requires(IsVectorAtCompileTime && R * C >= 3)
    {
        return Unit(2);
    }

    T*       data() noexcept { return d_; }
    const T* data() const noexcept { return d_; }

    T& elem(Index i, Index j) noexcept {
        assert(i >= 0 && i < R && j >= 0 && j < C);
        if constexpr (O == RowMajor)
            return d_[i * C + j];
        else
            return d_[i + j * R];
    }
    const T& elem(Index i, Index j) const noexcept {
        assert(i >= 0 && i < R && j >= 0 && j < C);
        if constexpr (O == RowMajor)
            return d_[i * C + j];
        else
            return d_[i + j * R];
    }

    // Views of this matrix (see DenseBase::block).
    template<int BR, int BC>
    Block<T, BR, BC> view(Index i, Index j) noexcept {
        assert(i >= 0 && j >= 0 && i + BR <= R && j + BC <= C);
        return Block<T, BR, BC>(d_ + i * rowStride() + j * colStride(), rowStride(), colStride());
    }
    template<int BR, int BC>
    Block<const T, BR, BC> cview(Index i, Index j) const noexcept {
        assert(i >= 0 && j >= 0 && i + BR <= R && j + BC <= C);
        return Block<const T, BR, BC>(
            d_ + i * rowStride() + j * colStride(), rowStride(), colStride());
    }

    template<bool End>
    iterator makeIterator() noexcept {
        return End ? d_ + R * C : d_;
    }
    const_iterator begin() const noexcept
        requires IsVectorAtCompileTime
    {
        return d_;
    }
    const_iterator end() const noexcept
        requires IsVectorAtCompileTime
    {
        return d_ + R * C;
    }
    using Base::begin;
    using Base::end;

    static constexpr Index rowStride() noexcept { return O == RowMajor ? C : 1; }
    static constexpr Index colStride() noexcept { return O == RowMajor ? 1 : R; }

private:
    static Matrix Unit(int k) noexcept {
        Matrix m = Zero();
        m.d_[k]  = T(1);
        return m;
    }
    template<class D2>
    void assignTo(const DenseBase<D2>& other) noexcept {
        if constexpr (traits<D2>::Rows == R && traits<D2>::Cols == C) {
            for (Index j = 0; j < C; ++j)
                for (Index i = 0; i < R; ++i) elem(i, j) = other.coeff(i, j);
        } else {
            for (Index k = 0; k < R * C; ++k) this->coeffRef(k) = other.coeff(k);
        }
    }

    T d_[R * C];
};

// ---------------------------------------------------------------------------------
// Block: a writable (or, for a const scalar, read-only) window with a row and a column
// stride. A `Map` is a block over caller-owned memory.

template<class T, int R, int C>
class Block : public WritableDense<Block<T, R, C>> {
    using Base = WritableDense<Block<T, R, C>>;

public:
    using Scalar                           = std::remove_const_t<T>;
    using RealScalar                       = Scalar;
    static constexpr int RowsAtCompileTime = R;
    static constexpr int ColsAtCompileTime = C;
    static constexpr int SizeAtCompileTime = R * C;
    using value_type                       = Scalar;
    using iterator                         = detail::StridedIterator<T>;
    using const_iterator                   = detail::StridedIterator<const Scalar>;

    Block(T* p, Index rowStride, Index colStride) noexcept: p_(p), rs_(rowStride), cs_(colStride) {}
    Block(const Block&) noexcept = default;

    // Assigning to a view writes into what it looks at.
    Block& operator=(const Block& other) noexcept
        requires(! std::is_const_v<T>)
    {
        this->assignFrom(other);
        return *this;
    }
    template<class D2>
        requires(! std::is_const_v<T> &&
                 (SameShape<Block, D2> || (Base::IsVectorAtCompileTime &&
                                           std::is_same_v<typename traits<D2>::Scalar, Scalar> &&
                                           traits<D2>::Rows == C && traits<D2>::Cols == R)))
    Block& operator=(const DenseBase<D2>& other) noexcept {
        if constexpr (SameShape<Block, D2>) {
            this->assignFrom(other);
        } else {
            const Matrix<Scalar, R, C> copy(other.derived());
            this->assignFrom(copy);
        }
        return *this;
    }

    T& elem(Index i, Index j) const noexcept {
        assert(i >= 0 && i < R && j >= 0 && j < C);
        return p_[i * rs_ + j * cs_];
    }
    T*    data() const noexcept { return p_; }
    Index rowStride() const noexcept { return rs_; }
    Index colStride() const noexcept { return cs_; }
    Index innerStride() const noexcept { return R == 1 ? cs_ : rs_; }

    template<int BR, int BC>
    Block<T, BR, BC> view(Index i, Index j) const noexcept {
        assert(i >= 0 && j >= 0 && i + BR <= R && j + BC <= C);
        return Block<T, BR, BC>(p_ + i * rs_ + j * cs_, rs_, cs_);
    }
    template<int BR, int BC>
    Block<const Scalar, BR, BC> cview(Index i, Index j) const noexcept {
        assert(i >= 0 && j >= 0 && i + BR <= R && j + BC <= C);
        return Block<const Scalar, BR, BC>(p_ + i * rs_ + j * cs_, rs_, cs_);
    }

    template<bool End>
    iterator makeIterator() noexcept {
        const Index stride = innerStride();
        return iterator(End ? p_ + (R * C) * stride : p_, stride);
    }
    const_iterator begin() const noexcept
        requires Base::IsVectorAtCompileTime
    {
        return const_iterator(p_, innerStride());
    }
    const_iterator end() const noexcept
        requires Base::IsVectorAtCompileTime
    {
        return const_iterator(p_ + (R * C) * innerStride(), innerStride());
    }
    using Base::begin;
    using Base::end;

private:
    T*    p_;
    Index rs_;
    Index cs_;
};

// A view over caller-owned scalars laid out as the matrix type `M` says:
// `Map<const Matrix4f>(ptr)` reads 16 floats as a column-major matrix.
template<class M>
class Map
    : public Block<
          std::conditional_t<std::is_const_v<M>, const typename M::Scalar, typename M::Scalar>,
          M::RowsAtCompileTime, M::ColsAtCompileTime> {
    using Elem =
        std::conditional_t<std::is_const_v<M>, const typename M::Scalar, typename M::Scalar>;
    using Super = Block<Elem, M::RowsAtCompileTime, M::ColsAtCompileTime>;

public:
    explicit Map(Elem* p) noexcept: Super(p, M::rowStride(), M::colStride()) {}
    using Super::operator=;
};

// ---------------------------------------------------------------------------------
// Column-wise iteration and reductions.

template<class T, int R, int C>
class Colwise {
public:
    using Scalar = std::remove_const_t<T>;

    class iterator {
    public:
        using iterator_category = std::input_iterator_tag;
        using value_type        = Block<T, R, 1>;
        using difference_type   = std::ptrdiff_t;
        using pointer           = void;
        using reference         = Block<T, R, 1>;

        iterator(T* p, Index rowStride, Index colStride) noexcept
            : p_(p), rs_(rowStride), cs_(colStride) {}
        reference operator*() const noexcept { return Block<T, R, 1>(p_, rs_, cs_); }
        iterator& operator++() noexcept {
            p_ += cs_;
            return *this;
        }
        friend bool operator==(const iterator& a, const iterator& b) noexcept {
            return a.p_ == b.p_;
        }

    private:
        T*    p_;
        Index rs_;
        Index cs_;
    };

    explicit Colwise(Block<T, R, C> whole) noexcept: whole_(whole) {}

    iterator begin() const noexcept {
        return iterator(whole_.data(), whole_.rowStride(), whole_.colStride());
    }
    iterator end() const noexcept {
        return iterator(
            whole_.data() + C * whole_.colStride(), whole_.rowStride(), whole_.colStride());
    }

    // The Euclidean norm of every column, as a row vector.
    Matrix<Scalar, 1, C> norm() const noexcept {
        Matrix<Scalar, 1, C> out;
        for (Index j = 0; j < C; ++j) out.elem(0, j) = whole_.template cview<R, 1>(0, j).norm();
        return out;
    }

private:
    Block<T, R, C> whole_;
};

// ---------------------------------------------------------------------------------
// Array: the coefficient-wise view of a matrix, with the few operations the engine uses
// on it (`m.array() == n.array()`, `(v.array() + shift) * scale`).

template<class T, int R, int C>
class Array {
public:
    using Scalar = T;

    Array() = default;
    static constexpr Index rows() noexcept { return R; }
    static constexpr Index cols() noexcept { return C; }
    static constexpr Index size() noexcept { return R * C; }

    T& operator()(Index i, Index j) noexcept { return d_[static_cast<std::size_t>(i + j * R)]; }
    const T& operator()(Index i, Index j) const noexcept {
        return d_[static_cast<std::size_t>(i + j * R)];
    }
    T&       operator()(Index k) noexcept { return d_[static_cast<std::size_t>(k)]; }
    const T& operator()(Index k) const noexcept { return d_[static_cast<std::size_t>(k)]; }
    T&       operator[](Index k) noexcept { return d_[static_cast<std::size_t>(k)]; }
    const T& operator[](Index k) const noexcept { return d_[static_cast<std::size_t>(k)]; }

    Matrix<T, R, C> matrix() const noexcept {
        Matrix<T, R, C> out;
        for (Index k = 0; k < size(); ++k) out.data()[k] = d_[static_cast<std::size_t>(k)];
        return out;
    }

    bool all() const noexcept {
        for (const T& v : d_)
            if (! v) return false;
        return true;
    }

    template<ArithmeticScalar S>
    friend Array operator+(const Array& a, S s) noexcept {
        const T t = static_cast<T>(s);
        return map(a, [t](T x) {
            return static_cast<T>(x + t);
        });
    }
    template<ArithmeticScalar S>
    friend Array operator*(const Array& a, S s) noexcept {
        const T t = static_cast<T>(s);
        return map(a, [t](T x) {
            return static_cast<T>(x * t);
        });
    }
    friend Array<bool, R, C> operator==(const Array& a, const Array& b) noexcept {
        Array<bool, R, C> out;
        for (Index k = 0; k < size(); ++k) out[k] = a[k] == b[k];
        return out;
    }

private:
    template<class F>
    static Array map(const Array& a, F f) noexcept {
        Array out;
        for (Index k = 0; k < size(); ++k) out[k] = f(a[k]);
        return out;
    }

    std::array<T, static_cast<std::size_t>(R* C)> d_;
};

template<class D>
Array<typename DenseBase<D>::Scalar, DenseBase<D>::RowsAtCompileTime,
      DenseBase<D>::ColsAtCompileTime>
DenseBase<D>::array() const noexcept {
    Array<Scalar, RowsAtCompileTime, ColsAtCompileTime> out;
    for (Index j = 0; j < cols(); ++j)
        for (Index i = 0; i < rows(); ++i) out(i, j) = coeff(i, j);
    return out;
}

// ---------------------------------------------------------------------------------
// `m << 1, 2, 3, ...` fills a matrix row by row.

template<class D>
class CommaInitializer {
public:
    using Scalar = typename traits<D>::Scalar;

    CommaInitializer(D& target, const Scalar& first) noexcept: m_(target) { put(first); }

    CommaInitializer& operator,(const Scalar& next) noexcept {
        put(next);
        return *this;
    }

private:
    void put(const Scalar& v) noexcept {
        assert(r_ < m_.rows());
        m_.elem(r_, c_) = v;
        if (++c_ == m_.cols()) {
            c_ = 0;
            ++r_;
        }
    }
    D&    m_;
    Index r_ { 0 };
    Index c_ { 0 };
};

template<class D>
CommaInitializer<D> DenseBase<D>::operator<<(const Scalar& first) noexcept {
    return CommaInitializer<D>(derived(), first);
}

// ---------------------------------------------------------------------------------
// Free operators. Every one returns a plain matrix.

template<class A, class B>
    requires SameShape<A, B>
LINALG_INLINE typename DenseBase<A>::PlainObject operator+(const DenseBase<A>& a,
                                                           const DenseBase<B>& b) noexcept {
    typename DenseBase<A>::PlainObject out;
    for (Index j = 0; j < a.cols(); ++j)
        for (Index i = 0; i < a.rows(); ++i) out.elem(i, j) = a.coeff(i, j) + b.coeff(i, j);
    return out;
}
template<class A, class B>
    requires SameShape<A, B>
LINALG_INLINE typename DenseBase<A>::PlainObject operator-(const DenseBase<A>& a,
                                                           const DenseBase<B>& b) noexcept {
    typename DenseBase<A>::PlainObject out;
    for (Index j = 0; j < a.cols(); ++j)
        for (Index i = 0; i < a.rows(); ++i) out.elem(i, j) = a.coeff(i, j) - b.coeff(i, j);
    return out;
}
template<class A>
LINALG_INLINE typename DenseBase<A>::PlainObject operator-(const DenseBase<A>& a) noexcept {
    typename DenseBase<A>::PlainObject out;
    for (Index j = 0; j < a.cols(); ++j)
        for (Index i = 0; i < a.rows(); ++i)
            out.elem(i, j) = static_cast<typename DenseBase<A>::Scalar>(-a.coeff(i, j));
    return out;
}
template<class A, ArithmeticScalar S>
LINALG_INLINE typename DenseBase<A>::PlainObject operator*(const DenseBase<A>& a, S s) noexcept {
    using T                              = typename DenseBase<A>::Scalar;
    const T                            t = static_cast<T>(s);
    typename DenseBase<A>::PlainObject out;
    for (Index j = 0; j < a.cols(); ++j)
        for (Index i = 0; i < a.rows(); ++i) out.elem(i, j) = a.coeff(i, j) * t;
    return out;
}
template<ArithmeticScalar S, class A>
LINALG_INLINE typename DenseBase<A>::PlainObject operator*(S s, const DenseBase<A>& a) noexcept {
    using T                              = typename DenseBase<A>::Scalar;
    const T                            t = static_cast<T>(s);
    typename DenseBase<A>::PlainObject out;
    for (Index j = 0; j < a.cols(); ++j)
        for (Index i = 0; i < a.rows(); ++i) out.elem(i, j) = t * a.coeff(i, j);
    return out;
}
template<class A, ArithmeticScalar S>
LINALG_INLINE typename DenseBase<A>::PlainObject operator/(const DenseBase<A>& a, S s) noexcept {
    using T                              = typename DenseBase<A>::Scalar;
    const T                            t = static_cast<T>(s);
    typename DenseBase<A>::PlainObject out;
    for (Index j = 0; j < a.cols(); ++j)
        for (Index i = 0; i < a.rows(); ++i) out.elem(i, j) = a.coeff(i, j) / t;
    return out;
}

// The matrix product. The arithmetic order of each entry is described with the
// reductions at the top of this file.
template<class A, class B>
    requires(std::is_same_v<typename traits<A>::Scalar, typename traits<B>::Scalar> &&
             traits<A>::Cols == traits<B>::Rows)
LINALG_INLINE Matrix<typename traits<A>::Scalar, traits<A>::Rows, traits<B>::Cols>
              operator*(const DenseBase<A>& a, const DenseBase<B>& b) noexcept {
    using T                                = typename traits<A>::Scalar;
    constexpr Index                  Rows  = traits<A>::Rows;
    constexpr Index                  Inner = traits<A>::Cols;
    constexpr Index                  Lanes = Rows - Rows % 2;
    Matrix<T, Rows, traits<B>::Cols> out;
    for (Index j = 0; j < b.cols(); ++j) {
        for (Index i = 0; i < Rows; ++i) {
            const auto x = [&](Index k) {
                return a.coeff(i, k);
            };
            const auto y = [&](Index k) {
                return b.coeff(k, j);
            };
            if constexpr (Rows == 1) {
                out.elem(i, j) = detail::Dot<T, Inner>(x, y);
            } else if (i < Lanes) {
                T s = x(0) * y(0);
                for (Index k = 1; k < Inner; ++k) s = detail::Fma<T>(x(k), y(k), s);
                out.elem(i, j) = s;
            } else {
                out.elem(i, j) = detail::RowDot<T, Inner>(x, y);
            }
        }
    }
    return out;
}

template<class A, class B>
    requires SameShape<A, B>
LINALG_INLINE bool operator==(const DenseBase<A>& a, const DenseBase<B>& b) noexcept {
    for (Index j = 0; j < a.cols(); ++j)
        for (Index i = 0; i < a.rows(); ++i)
            if (! (a.coeff(i, j) == b.coeff(i, j))) return false;
    return true;
}

// Streams one row per line, coefficients separated by a space and right-aligned to
// the widest one, in the stream's own number format. For logs and test failures.
template<class D>
std::ostream& operator<<(std::ostream& os, const DenseBase<D>& m) {
    std::array<std::string, static_cast<std::size_t>(DenseBase<D>::SizeAtCompileTime)> text;
    std::size_t                                                                        width = 0;
    for (Index j = 0; j < m.cols(); ++j) {
        for (Index i = 0; i < m.rows(); ++i) {
            std::ostringstream one;
            one.copyfmt(os);
            one.width(0);
            one << m.coeff(i, j);
            auto& s = text[static_cast<std::size_t>(i + j * m.rows())];
            s       = one.str();
            width   = std::max(width, s.size());
        }
    }
    for (Index i = 0; i < m.rows(); ++i) {
        for (Index j = 0; j < m.cols(); ++j) {
            if (j != 0) os << ' ';
            os.width(static_cast<std::streamsize>(width));
            os << text[static_cast<std::size_t>(i + j * m.rows())];
        }
        if (i + 1 < m.rows()) os << '\n';
    }
    return os;
}

// --- the engine's vocabulary ----------------------------------------------------------

using Vector2f = Matrix<float, 2, 1>;
using Vector3f = Matrix<float, 3, 1>;
using Vector4f = Matrix<float, 4, 1>;
using Vector2d = Matrix<double, 2, 1>;
using Vector3d = Matrix<double, 3, 1>;
using Vector4d = Matrix<double, 4, 1>;
using Vector2i = Matrix<int, 2, 1>;
using Vector3i = Matrix<int, 3, 1>;
using Vector4i = Matrix<int, 4, 1>;
using Matrix2f = Matrix<float, 2, 2>;
using Matrix3f = Matrix<float, 3, 3>;
using Matrix4f = Matrix<float, 4, 4>;
using Matrix2d = Matrix<double, 2, 2>;
using Matrix3d = Matrix<double, 3, 3>;
using Matrix4d = Matrix<double, 4, 4>;

} // namespace wallpaper::linalg

#pragma float_control(pop)
