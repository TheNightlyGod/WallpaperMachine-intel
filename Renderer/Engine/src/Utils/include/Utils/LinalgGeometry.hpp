// Rotations, 3D transforms and the pivoted LU the scene engine uses, on top of the
// dense types in LinalgDense.hpp.
//
// This is this project's own code, written from the mathematics (the Hamilton
// product, Rodrigues' rotation formula, spherical linear interpolation, Gaussian
// elimination with full pivoting). It is not derived from any other library's source.
// The names (`Quaternion`, `AngleAxis`, `Transform`, `prerotate`, `slerp`, ...) are
// the conventional ones so call sites read as they always have.
#pragma once

#include "Utils/LinalgDense.hpp"

#pragma float_control(push)
#pragma clang fp contract(off)

namespace wallpaper::linalg
{

template<class T>
class Quaternion;
template<class T>
class AngleAxis;

// A rotation of `angle` radians about the unit vector `axis`.
template<class T>
class AngleAxis {
public:
    using Scalar  = T;
    using Vector3 = Matrix<T, 3, 1>;

    AngleAxis() = default;
    AngleAxis(const T& angle, const Vector3& axis) noexcept: angle_(angle), axis_(axis) {}
    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 3 &&
                 traits<D>::Cols == 1 && ! std::is_same_v<D, Matrix<T, 3, 1>>)
    AngleAxis(const T& angle, const DenseBase<D>& axis) noexcept: angle_(angle), axis_(axis) {}

    T&             angle() noexcept { return angle_; }
    const T&       angle() const noexcept { return angle_; }
    Vector3&       axis() noexcept { return axis_; }
    const Vector3& axis() const noexcept { return axis_; }

    // Rodrigues' formula: R = cos(a) I + sin(a) [axis]x + (1 - cos(a)) axis axis^T.
    Matrix<T, 3, 3> toRotationMatrix() const noexcept {
        const T         s  = std::sin(angle_);
        const T         c  = std::cos(angle_);
        const T         k  = T(1) - c;
        const T         sx = s * axis_.x(), sy = s * axis_.y(), sz = s * axis_.z();
        const T         kx = k * axis_.x(), ky = k * axis_.y(), kz = k * axis_.z();
        Matrix<T, 3, 3> r;
        T               tmp = kx * axis_.y();
        r.elem(0, 1)        = tmp - sz;
        r.elem(1, 0)        = tmp + sz;
        tmp                 = kx * axis_.z();
        r.elem(0, 2)        = tmp + sy;
        r.elem(2, 0)        = tmp - sy;
        tmp                 = ky * axis_.z();
        r.elem(1, 2)        = tmp - sx;
        r.elem(2, 1)        = tmp + sx;
        r.elem(0, 0)        = kx * axis_.x() + c;
        r.elem(1, 1)        = ky * axis_.y() + c;
        r.elem(2, 2)        = kz * axis_.z() + c;
        return r;
    }

    Quaternion<T> operator*(const AngleAxis& other) const noexcept;
    Quaternion<T> operator*(const Quaternion<T>& other) const noexcept;

private:
    T       angle_;
    Vector3 axis_;
};

using AngleAxisf = AngleAxis<float>;
using AngleAxisd = AngleAxis<double>;

// A rotation as a unit quaternion. Stored as (x, y, z, w) like the coefficient order of
// `coeffs()`, constructed as (w, x, y, z).
template<class T>
class Quaternion {
public:
    using Scalar       = T;
    using Vector3      = Matrix<T, 3, 1>;
    using Coefficients = Matrix<T, 4, 1>;

    Quaternion() = default;
    Quaternion(const T& w, const T& x, const T& y, const T& z) noexcept: c_(x, y, z, w) {}
    explicit Quaternion(const AngleAxis<T>& aa) noexcept {
        const T half    = T(0.5) * aa.angle();
        const T s       = std::sin(half);
        c_(3)           = std::cos(half);
        const Vector3 v = s * aa.axis();
        c_(0)           = v.x();
        c_(1)           = v.y();
        c_(2)           = v.z();
    }
    // From a 4-vector of coefficients (x, y, z, w), or from a 3 x 3 rotation matrix.
    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> &&
                 ((traits<D>::Rows == 4 && traits<D>::Cols == 1) ||
                  (traits<D>::Rows == 3 && traits<D>::Cols == 3)))
    explicit Quaternion(const DenseBase<D>& m) noexcept {
        if constexpr (traits<D>::Rows == 4) {
            c_ = m.derived();
        } else {
            fromRotationMatrix(m);
        }
    }

    static Quaternion Identity() noexcept { return Quaternion(T(1), T(0), T(0), T(0)); }

    Coefficients&       coeffs() noexcept { return c_; }
    const Coefficients& coeffs() const noexcept { return c_; }
    T&                  x() noexcept { return c_(0); }
    T&                  y() noexcept { return c_(1); }
    T&                  z() noexcept { return c_(2); }
    T&                  w() noexcept { return c_(3); }
    const T&            x() const noexcept { return c_(0); }
    const T&            y() const noexcept { return c_(1); }
    const T&            z() const noexcept { return c_(2); }
    const T&            w() const noexcept { return c_(3); }
    auto                vec() noexcept { return c_.template head<3>(); }
    auto                vec() const noexcept { return c_.template head<3>(); }

    T squaredNorm() const noexcept { return c_.squaredNorm(); }
    T norm() const noexcept { return c_.norm(); }
    T dot(const Quaternion& other) const noexcept { return c_.dot(other.c_); }

    Quaternion normalized() const noexcept { return Quaternion(c_.normalized()); }
    void       normalize() noexcept { c_.normalize(); }

    Quaternion conjugate() const noexcept { return Quaternion(w(), -x(), -y(), -z()); }

    // The Hamilton product: this rotation applied after `other`. Each component is a
    // sum of four products. The products are paired and the pairs added in an order that
    // differs between floats and doubles and between components, with the sign flips
    // placed where they keep the sign of an exact zero result: the engine's rotations
    // are full of exact zeros, and a rotation by pi about Z turns on the sign of one.
    Quaternion operator*(const Quaternion& o) const noexcept {
        const T aw = w(), ax = x(), ay = y(), az = z();
        const T bw = o.w(), bx = o.x(), by = o.y(), bz = o.z();
        T       rx, ry, rz, rw;
        if constexpr (sizeof(T) == 4) {
            {
                const T p0 = aw * bx, p1 = ax * bw, p2 = ay * bz, p3 = az * by;
                rx = (p1 - p3) + (p2 + p0);
            }
            {
                const T p0 = aw * by, p1 = ay * bw, p2 = az * bx, p3 = ax * bz;
                ry = (-p3 + p1) + (p2 + p0);
            }
            {
                const T p0 = aw * bz, p1 = az * bw, p2 = ax * by, p3 = ay * bx;
                rz = (p1 - p3) + (p2 + p0);
            }
            {
                const T p0 = aw * bw, p1 = ax * bx, p2 = ay * by, p3 = az * bz;
                rw = -(p3 + p2) + (p0 - p1);
            }
        } else {
            {
                const T p0 = aw * bx, p1 = ax * bw, p2 = ay * bz, p3 = az * by;
                rx = -(-p1 - -p3) + (p0 + p2);
            }
            {
                const T p0 = aw * by, p1 = ay * bw, p2 = az * bx, p3 = ax * bz;
                ry = (p1 + p0) + (-p3 + p2);
            }
            {
                const T p0 = aw * bz, p1 = az * bw, p2 = ax * by, p3 = ay * bx;
                rz = (p0 - p3) + (p1 + p2);
            }
            {
                const T p0 = aw * bw, p1 = ax * bx, p2 = ay * by, p3 = az * bz;
                rw = (-p2 + p0) - (p3 + p1);
            }
        }
        return Quaternion(rw, rx, ry, rz);
    }
    Quaternion& operator*=(const Quaternion& other) noexcept {
        *this = *this * other;
        return *this;
    }

    // Spherical linear interpolation along the shorter arc, `t` in [0, 1]. Nearly
    // parallel quaternions interpolate linearly. The result is not renormalised.
    Quaternion slerp(const T& t, const Quaternion& other) const noexcept {
        const T one = T(1) - std::numeric_limits<T>::epsilon();
        const T d   = dot(other);
        const T ad  = detail::Abs(d);
        T       s0, s1;
        if (ad >= one) {
            s0 = T(1) - t;
            s1 = t;
        } else {
            const T theta = std::acos(ad);
            const T sinTheta =
                std::sqrt(detail::Fma<T>(-ad, ad, T(1))); // sin(acos(ad)), rounded once
            s0 = std::sin((T(1) - t) * theta) / sinTheta;
            s1 = std::sin(t * theta) / sinTheta;
        }
        if (d < T(0)) s1 = -s1;
        return Quaternion(Coefficients(s0 * c_ + s1 * other.c_));
    }

    Matrix<T, 3, 3> toRotationMatrix() const noexcept {
        const T         tx = T(2) * x(), ty = T(2) * y(), tz = T(2) * z();
        const T         twx = tx * w(), twy = ty * w(), twz = tz * w();
        const T         txx = tx * x(), txy = ty * x(), txz = tz * x();
        const T         tyy = ty * y(), tyz = tz * y(), tzz = tz * z();
        Matrix<T, 3, 3> r;
        r.elem(0, 0) = T(1) - (tyy + tzz);
        r.elem(0, 1) = txy - twz;
        r.elem(0, 2) = txz + twy;
        r.elem(1, 0) = txy + twz;
        r.elem(1, 1) = T(1) - (txx + tzz);
        r.elem(1, 2) = tyz - twx;
        r.elem(2, 0) = txz - twy;
        r.elem(2, 1) = tyz + twx;
        r.elem(2, 2) = T(1) - (txx + tyy);
        return r;
    }

    template<class U>
    Quaternion<U> cast() const noexcept {
        return Quaternion<U>(c_.template cast<U>());
    }

    friend bool operator==(const Quaternion& a, const Quaternion& b) noexcept {
        return a.c_ == b.c_;
    }

private:
    // The standard conversion: the trace when it is positive, otherwise the largest
    // diagonal entry picks the numerically safe branch.
    template<class D>
    void fromRotationMatrix(const DenseBase<D>& m) noexcept {
        T t = m.coeff(0, 0) + (m.coeff(1, 1) + m.coeff(2, 2));
        if (t > T(0)) {
            t   = std::sqrt(t + T(1));
            w() = T(0.5) * t;
            t   = T(0.5) / t;
            x() = (m.coeff(2, 1) - m.coeff(1, 2)) * t;
            y() = (m.coeff(0, 2) - m.coeff(2, 0)) * t;
            z() = (m.coeff(1, 0) - m.coeff(0, 1)) * t;
        } else {
            Index i = 0;
            if (m.coeff(1, 1) > m.coeff(0, 0)) i = 1;
            if (m.coeff(2, 2) > m.coeff(i, i)) i = 2;
            const Index j = (i + 1) % 3;
            const Index k = (j + 1) % 3;
            t             = std::sqrt(m.coeff(i, i) - m.coeff(j, j) - m.coeff(k, k) + T(1));
            c_(i)         = T(0.5) * t;
            t             = T(0.5) / t;
            w()           = (m.coeff(k, j) - m.coeff(j, k)) * t;
            c_(j)         = (m.coeff(j, i) + m.coeff(i, j)) * t;
            c_(k)         = (m.coeff(k, i) + m.coeff(i, k)) * t;
        }
    }

    Coefficients c_;
};

using Quaternionf = Quaternion<float>;
using Quaterniond = Quaternion<double>;

template<class T>
Quaternion<T> AngleAxis<T>::operator*(const AngleAxis& other) const noexcept {
    return Quaternion<T>(*this) * Quaternion<T>(other);
}
template<class T>
Quaternion<T> AngleAxis<T>::operator*(const Quaternion<T>& other) const noexcept {
    return Quaternion<T>(*this) * other;
}
template<class T>
Quaternion<T> operator*(const Quaternion<T>& q, const AngleAxis<T>& aa) noexcept {
    return q * Quaternion<T>(aa);
}
// A rotation applied to a vector or a 3 x 3 matrix.
template<class T, class D>
    requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 3)
Matrix<T, 3, traits<D>::Cols> operator*(const AngleAxis<T>& aa, const DenseBase<D>& m) noexcept {
    return aa.toRotationMatrix() * m;
}

// ---------------------------------------------------------------------------------
// Translations and scalings, as values that build a Transform.

template<class T, int Dim = 3>
class Translation {
public:
    static_assert(Dim == 3);
    using Scalar  = T;
    using Vector3 = Matrix<T, 3, 1>;

    Translation() = default;
    Translation(const T& x, const T& y, const T& z) noexcept: v_(x, y, z) {}
    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 3 &&
                 traits<D>::Cols == 1)
    explicit Translation(const DenseBase<D>& v) noexcept: v_(v) {}

    Vector3&       vector() noexcept { return v_; }
    const Vector3& vector() const noexcept { return v_; }

private:
    Vector3 v_;
};
using Translation3f = Translation<float>;
using Translation3d = Translation<double>;

// A diagonal scaling of N-dimensional space: applied to a vector it scales each
// coordinate; `Transform` builds the 3D one into a matrix.
template<class T, int N = 3>
struct DiagonalScaling {
    Matrix<T, N, 1> diagonal;

    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == N &&
                 traits<D>::Cols == 1)
    Matrix<T, N, 1> operator*(const DenseBase<D>& v) const noexcept {
        Matrix<T, N, 1> out;
        for (Index i = 0; i < N; ++i) out.elem(i, 0) = diagonal.coeff(i) * v.coeff(i);
        return out;
    }
};
template<class T>
DiagonalScaling<T, 2> Scaling(const T& sx, const T& sy) noexcept {
    return DiagonalScaling<T, 2> { Matrix<T, 2, 1>(sx, sy) };
}
template<class T>
DiagonalScaling<T, 3> Scaling(const T& sx, const T& sy, const T& sz) noexcept {
    return DiagonalScaling<T, 3> { Matrix<T, 3, 1>(sx, sy, sz) };
}
template<class D>
    requires(traits<D>::Cols == 1 && (traits<D>::Rows == 2 || traits<D>::Rows == 3))
DiagonalScaling<typename traits<D>::Scalar, traits<D>::Rows>
Scaling(const DenseBase<D>& v) noexcept {
    return DiagonalScaling<typename traits<D>::Scalar, traits<D>::Rows> {
        Matrix<typename traits<D>::Scalar, traits<D>::Rows, 1>(v)
    };
}

// ---------------------------------------------------------------------------------
// Transform: a 4 x 4 homogeneous matrix of a 3D transformation.
//
// In `Affine` mode the last row is always (0, 0, 0, 1) and only the top three rows are
// ever computed. In `Projective` mode all sixteen entries are free.
//
// `prerotate`, `pretranslate` and `prescale` apply the new operation after everything
// already in the transform (T' = N * T); `rotate`, `translate` and `scale` apply it
// before (T' = T * N). `scale` and `rotate` touch only the linear 3 x 3 part, in both
// modes.

enum TransformTraits : int
{
    Isometry      = 1,
    Affine        = 2,
    AffineCompact = 3,
    Projective    = 32,
};

template<class T, int Dim, int Mode>
class Transform {
    static_assert(Dim == 3, "only 3D transforms are supported");
    static_assert(Mode == Affine || Mode == Projective);

public:
    using Scalar     = T;
    using MatrixType = Matrix<T, 4, 4>;
    using Vector3    = Matrix<T, 3, 1>;

    // Zeroed, with the affine bottom row for Affine mode.
    Transform() noexcept: m_(MatrixType::Zero()) {
        if constexpr (Mode == Affine) m_.elem(3, 3) = T(1);
    }
    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 4 &&
                 traits<D>::Cols == 4)
    explicit Transform(const DenseBase<D>& m) noexcept: m_(m) {}
    Transform(const Translation<T>& t) noexcept: Transform(Identity()) { // NOLINT: implicit, as a translation is a transform
        translation() = t.vector();
    }
    Transform(const DiagonalScaling<T, 3>& s) noexcept: Transform(Identity()) { // NOLINT
        m_.elem(0, 0) = s.diagonal.x();
        m_.elem(1, 1) = s.diagonal.y();
        m_.elem(2, 2) = s.diagonal.z();
    }

    static Transform Identity() noexcept {
        Transform t;
        t.m_ = MatrixType::Identity();
        return t;
    }

    MatrixType&       matrix() noexcept { return m_; }
    const MatrixType& matrix() const noexcept { return m_; }
    T&                operator()(Index i, Index j) noexcept { return m_.elem(i, j); }
    const T&          operator()(Index i, Index j) const noexcept { return m_.elem(i, j); }
    T*                data() noexcept { return m_.data(); }
    const T*          data() const noexcept { return m_.data(); }

    Block<T, 3, 3>       linear() noexcept { return m_.template block<3, 3>(0, 0); }
    Block<const T, 3, 3> linear() const noexcept { return m_.template block<3, 3>(0, 0); }
    Block<T, 3, 1>       translation() noexcept { return m_.template block<3, 1>(0, 3); }
    Block<const T, 3, 1> translation() const noexcept { return m_.template block<3, 1>(0, 3); }

    // Scales the rows of the top 3 x 4 part: T' = diag(s, 1) * T.
    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 3 &&
                 traits<D>::Cols == 1)
    Transform& prescale(const DenseBase<D>& s) noexcept {
        for (Index j = 0; j < 4; ++j)
            for (Index i = 0; i < 3; ++i) m_.elem(i, j) = s.coeff(i) * m_.elem(i, j);
        return *this;
    }
    // Scales the first three columns: T' = T * diag(s, 1). In Affine mode the bottom
    // row is zero there and is left alone; in Projective mode it is scaled with the rest.
    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 3 &&
                 traits<D>::Cols == 1)
    Transform& scale(const DenseBase<D>& s) noexcept {
        constexpr Index Rows = Mode == Affine ? 3 : 4;
        for (Index j = 0; j < 3; ++j)
            for (Index i = 0; i < Rows; ++i) m_.elem(i, j) = m_.elem(i, j) * s.coeff(j);
        return *this;
    }

    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 3 &&
                 traits<D>::Cols == 1)
    Transform& pretranslate(const DenseBase<D>& v) noexcept {
        if constexpr (Mode == Affine) {
            for (Index i = 0; i < 3; ++i) m_.elem(i, 3) += v.coeff(i);
        } else {
            for (Index j = 0; j < 4; ++j)
                for (Index i = 0; i < 3; ++i) m_.elem(i, j) += v.coeff(i) * m_.elem(3, j);
        }
        return *this;
    }
    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 3 &&
                 traits<D>::Cols == 1)
    Transform& translate(const DenseBase<D>& v) noexcept {
        if constexpr (Mode == Affine) {
            const Vector3 moved = linear() * v;
            for (Index i = 0; i < 3; ++i) m_.elem(i, 3) += moved.coeff(i);
        } else {
            const Matrix<T, 4, 1> moved = m_.template block<4, 3>(0, 0) * v;
            for (Index i = 0; i < 4; ++i) m_.elem(i, 3) += moved.coeff(i);
        }
        return *this;
    }

    // Rotations: an AngleAxis, a Quaternion or a 3 x 3 rotation matrix.
    Transform& prerotate(const AngleAxis<T>& r) noexcept {
        return prerotateBy(r.toRotationMatrix());
    }
    Transform& prerotate(const Quaternion<T>& r) noexcept {
        return prerotateBy(r.toRotationMatrix());
    }
    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 3 &&
                 traits<D>::Cols == 3)
    Transform& prerotate(const DenseBase<D>& r) noexcept {
        return prerotateBy(Matrix<T, 3, 3>(r));
    }
    Transform& rotate(const AngleAxis<T>& r) noexcept { return rotateBy(r.toRotationMatrix()); }
    Transform& rotate(const Quaternion<T>& r) noexcept { return rotateBy(r.toRotationMatrix()); }
    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 3 &&
                 traits<D>::Cols == 3)
    Transform& rotate(const DenseBase<D>& r) noexcept {
        return rotateBy(Matrix<T, 3, 3>(r));
    }

    // Composition. An affine product never computes the bottom row: the linear parts
    // multiply, and the translation is the left linear part applied to the right
    // translation plus the left translation.
    Transform operator*(const Transform& other) const noexcept {
        Transform out;
        if constexpr (Mode == Affine) {
            const Matrix<T, 3, 3> lin         = linear() * other.linear();
            const Vector3         trans       = (linear() * other.translation()) + translation();
            out.m_.template block<3, 3>(0, 0) = lin;
            out.m_.template block<3, 1>(0, 3) = trans;
        } else {
            out.m_ = m_ * other.m_;
        }
        return out;
    }
    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 4 &&
                 traits<D>::Cols == 4)
    MatrixType operator*(const DenseBase<D>& other) const noexcept {
        return product4(other);
    }
    // A point: the linear part applied, then the translation added.
    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 3 &&
                 traits<D>::Cols == 1)
    Vector3 operator*(const DenseBase<D>& p) const noexcept {
        if constexpr (Mode == Affine) {
            // Every row (the odd third one too) is a chain of fused multiply-adds over
            // the three coordinates, the translation added last.
            Vector3 out;
            for (Index i = 0; i < 3; ++i) {
                T r            = m_.elem(i, 0) * p.coeff(0);
                r              = detail::Fma<T>(m_.elem(i, 1), p.coeff(1), r);
                r              = detail::Fma<T>(m_.elem(i, 2), p.coeff(2), r);
                out.elem(i, 0) = r + m_.elem(i, 3);
            }
            return out;
        } else {
            return (linear() * p) + translation();
        }
    }
    template<class D>
        requires(std::is_same_v<typename traits<D>::Scalar, T> && traits<D>::Rows == 4 &&
                 traits<D>::Cols == 4)
    Transform& operator*=(const DenseBase<D>& other) noexcept {
        m_ = product4(other);
        return *this;
    }
    Transform& operator*=(const Translation<T>& t) noexcept { return translate(t.vector()); }

    // An affine transform inverts through its linear part; a projective one as a 4 x 4.
    Transform inverse() const noexcept {
        Transform out;
        if constexpr (Mode == Affine) {
            const Matrix<T, 3, 3> inv         = linear().inverse();
            out.m_.template block<3, 3>(0, 0) = inv;
            out.m_.template block<3, 1>(0, 3) = (-inv) * translation();
        } else {
            out.m_ = m_.inverse();
        }
        return out;
    }

private:
    // This transform times a 4 x 4 matrix. An affine transform's bottom row is (0, 0,
    // 0, 1), so the product's bottom row is the other matrix's, copied.
    template<class D>
    MatrixType product4(const DenseBase<D>& other) const noexcept {
        if constexpr (Mode == Affine) {
            MatrixType            out;
            const Matrix<T, 3, 4> top      = m_.template block<3, 4>(0, 0) * other;
            out.template block<3, 4>(0, 0) = top;
            for (Index j = 0; j < 4; ++j) out.elem(3, j) = other.coeff(3, j);
            return out;
        } else {
            return m_ * other;
        }
    }
    Transform& prerotateBy(const Matrix<T, 3, 3>& r) noexcept {
        const Matrix<T, 3, 4> top     = r * m_.template block<3, 4>(0, 0);
        m_.template block<3, 4>(0, 0) = top;
        return *this;
    }
    Transform& rotateBy(const Matrix<T, 3, 3>& r) noexcept {
        const Matrix<T, 3, 3> moved = linear() * r;
        linear()                    = moved;
        return *this;
    }

    MatrixType m_;
};

using Affine3f     = Transform<float, 3, Affine>;
using Affine3d     = Transform<double, 3, Affine>;
using Projective3f = Transform<float, 3, Projective>;
using Projective3d = Transform<double, 3, Projective>;

// ---------------------------------------------------------------------------------
// FullPivLU: Gaussian elimination that takes the largest remaining entry as the pivot at
// every step, for the invertibility test and the inverse of a square matrix.

template<class M>
class FullPivLU {
    static_assert(M::RowsAtCompileTime == M::ColsAtCompileTime);

public:
    using Scalar              = typename M::Scalar;
    static constexpr int Size = M::RowsAtCompileTime;
    using PlainMatrix         = Matrix<Scalar, Size, Size>;

    explicit FullPivLU(const M& m) noexcept: lu_(m) {
        for (int i = 0; i < Size; ++i) {
            rowPerm_[static_cast<std::size_t>(i)] = i;
            colPerm_[static_cast<std::size_t>(i)] = i;
        }
        maxPivot_ = Scalar(0);
        nonzero_  = 0;
        for (int k = 0; k < Size; ++k) {
            // Largest magnitude in the not yet eliminated corner, first one in column
            // order on a tie.
            Scalar biggest = Scalar(-1);
            int    pr = k, pc = k;
            for (int j = k; j < Size; ++j) {
                for (int i = k; i < Size; ++i) {
                    const Scalar a = detail::Abs(lu_.elem(i, j));
                    if (a > biggest) {
                        biggest = a;
                        pr      = i;
                        pc      = j;
                    }
                }
            }
            if (biggest == Scalar(0)) break;
            nonzero_ = k + 1;
            if (pr != k) {
                for (int j = 0; j < Size; ++j) std::swap(lu_.elem(k, j), lu_.elem(pr, j));
                std::swap(rowPerm_[static_cast<std::size_t>(k)],
                          rowPerm_[static_cast<std::size_t>(pr)]);
            }
            if (pc != k) {
                for (int i = 0; i < Size; ++i) std::swap(lu_.elem(i, k), lu_.elem(i, pc));
                std::swap(colPerm_[static_cast<std::size_t>(k)],
                          colPerm_[static_cast<std::size_t>(pc)]);
            }
            maxPivot_          = std::max(maxPivot_, detail::Abs(lu_.elem(k, k)));
            const Scalar pivot = lu_.elem(k, k);
            for (int i = k + 1; i < Size; ++i) lu_.elem(i, k) /= pivot;
            for (int j = k + 1; j < Size; ++j)
                for (int i = k + 1; i < Size; ++i)
                    lu_.elem(i, j) -= lu_.elem(i, k) * lu_.elem(k, j);
        }
    }

    // Pivots no larger than this fraction of the biggest pivot count as zero.
    Scalar threshold() const noexcept {
        return std::numeric_limits<Scalar>::epsilon() * static_cast<Scalar>(Size);
    }
    int rank() const noexcept {
        const Scalar limit = detail::Abs(maxPivot_) * threshold();
        int          count = 0;
        for (int i = 0; i < nonzero_; ++i)
            if (detail::Abs(lu_.elem(i, i)) > limit) ++count;
        return count;
    }
    bool isInvertible() const noexcept { return rank() == Size; }

    // Solves A X = I with the factorisation: X = Q U^-1 L^-1 P.
    PlainMatrix inverse() const noexcept {
        PlainMatrix out;
        for (int col = 0; col < Size; ++col) {
            std::array<Scalar, static_cast<std::size_t>(Size)> x {};
            // P * e_col: the permuted identity column.
            for (int i = 0; i < Size; ++i)
                x[static_cast<std::size_t>(i)] =
                    rowPerm_[static_cast<std::size_t>(i)] == col ? Scalar(1) : Scalar(0);
            for (int k = 0; k < Size; ++k) // L has a unit diagonal
                for (int i = k + 1; i < Size; ++i)
                    x[static_cast<std::size_t>(i)] =
                        detail::Fma<Scalar>(-x[static_cast<std::size_t>(k)],
                                            lu_.elem(i, k),
                                            x[static_cast<std::size_t>(i)]);
            for (int k = Size - 1; k >= 0; --k) {
                x[static_cast<std::size_t>(k)] *= Scalar(1) / lu_.elem(k, k);
                for (int i = 0; i < k; ++i)
                    x[static_cast<std::size_t>(i)] =
                        detail::Fma<Scalar>(-x[static_cast<std::size_t>(k)],
                                            lu_.elem(i, k),
                                            x[static_cast<std::size_t>(i)]);
            }
            for (int i = 0; i < Size; ++i)
                out.elem(colPerm_[static_cast<std::size_t>(i)], col) =
                    x[static_cast<std::size_t>(i)];
        }
        return out;
    }

private:
    PlainMatrix                                     lu_;
    std::array<int, static_cast<std::size_t>(Size)> rowPerm_;
    std::array<int, static_cast<std::size_t>(Size)> colPerm_;
    Scalar                                          maxPivot_;
    int                                             nonzero_;
};

// ---------------------------------------------------------------------------------
// Camera matrices (right-handed, looking down -Z, depth mapped to [0, 1]).

constexpr double Radians(double a) noexcept { return (a / 180.0f) * Pi; }

// The camera's own frame as columns: `b` points from the target back to the eye, `r`
// is `up x b` and `u` is `b x r`, so the upper-left block holds `r`, `u`, `b` and the
// last column is that block applied to `-eye`. Coincident eye and target leave the
// block, and so the translation, zero rather than not-a-number.
inline Matrix4d LookAt(Vector3d eye, Vector3d center, Vector3d up) noexcept {
    const Vector3d b = (eye - center).normalized();
    const Vector3d r = up.cross(b).normalized();
    const Vector3d u = b.cross(r).normalized();

    Matrix4d m = Matrix4d::Identity();
    for (int i = 0; i < 3; ++i) {
        m.elem(i, 0) = r.coeff(i);
        m.elem(i, 1) = u.coeff(i);
        m.elem(i, 2) = b.coeff(i);
        m.elem(i, 3) = -(r.coeff(i) * eye.x() + u.coeff(i) * eye.y() + b.coeff(i) * eye.z());
    }
    return m;
}

// View x in [left, right] and y in [bottom, top] map to [-1, 1]; view z of -near and
// -far map to depth 0 and 1.
inline Matrix4d Ortho(double left, double right, double bottom, double top, double near,
                      double far) noexcept {
    Matrix4d m   = Matrix4d::Identity();
    m.elem(0, 0) = 2.0 / (right - left);
    m.elem(1, 1) = 2.0 / (top - bottom);
    m.elem(2, 2) = -1.0 / (far - near);
    m.elem(0, 3) = -(right + left) / (right - left);
    m.elem(1, 3) = -(top + bottom) / (top - bottom);
    m.elem(2, 3) = -near / (far - near);
    return m;
}

// `fovY` is the vertical field of view in radians, `aspect` width over height. Clip w
// is the negated view z; depth after the divide runs 0 at `near` to 1 at `far`.
inline Matrix4d Perspective(double fovY, double aspect, double near, double far) noexcept {
    const double t = std::tan(fovY / 2.0);
    Matrix4d     m = Matrix4d::Zero();
    m.elem(0, 0)   = 1.0 / (aspect * t);
    m.elem(1, 1)   = 1.0 / t;
    m.elem(2, 2)   = -far / (far - near);
    m.elem(2, 3)   = -(near * far) / (far - near);
    m.elem(3, 2)   = -1.0;
    return m;
}

} // namespace wallpaper::linalg

#pragma float_control(pop)
