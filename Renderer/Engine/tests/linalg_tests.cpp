// Utils/Linalg.hpp, the scene engine's own linear algebra: golden values captured from
// the library it replaced, and the behaviour the engine's call sites rely on, written
// out from the mathematics so it holds without any other library to compare with.
#include "linalg_cases.hpp"
#include "linalg_libm_canary.hpp"

#include "Utils/Linalg.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <numeric>
#include <sstream>
#include <type_traits>
#include <vector>

namespace
{
using namespace linalg_cases;
namespace la = wallpaper::linalg;

// --- golden values ---------------------------------------------------------------------

struct GoldenOp {
    const char*        name;
    int                cases;
    bool               usesLibm;
    double             tol;
    std::uint64_t      hash;
    std::size_t        count;
    const double*      values;
    const std::size_t* ends;
};
#include "linalg_golden.inc"

bool LibmMatchesCapture() {
    const auto now = LibmCanary();
    return now.size() == std::size(kLibmCanary) &&
           std::equal(now.begin(), now.end(), std::begin(kLibmCanary));
}

class LinalgGolden : public ::testing::TestWithParam<std::string> {};

// The case lists produce, bit for bit, what the previous library produced when the
// golden file was captured (or, for the cases that only owe a tolerance, values within
// it). A case that calls trigonometry is held to the bits only where the C library
// still rounds the way it did at capture.
TEST_P(LinalgGolden, ReproducesTheCapturedResults) {
    const std::string& name   = GetParam();
    const GoldenOp*    golden = nullptr;
    for (const auto& g : kGoldenOps)
        if (name == g.name) golden = &g;
    ASSERT_NE(golden, nullptr) << "no golden entry for " << name
                               << "; the golden file lists every case list";
    for (const auto& op : Registry<NewLib>()) {
        if (name != op.spec.name) continue;
        ASSERT_EQ(op.spec.cases, golden->cases);
        Out                      values;
        std::vector<std::size_t> ends;
        RunOp(op, values, ends);
        ASSERT_EQ(values.size(), golden->count);
        if (golden->tol > 0.0) {
            ASSERT_NE(golden->values, nullptr);
            ASSERT_EQ(ends.size(), static_cast<std::size_t>(golden->cases));
            for (std::size_t c = 0; c < ends.size(); ++c)
                EXPECT_EQ(ends[c], golden->ends[c]) << name << " case " << c;
            std::size_t bad = 0;
            for (std::size_t i = 0; i < values.size() && bad < 5; ++i) {
                const double x = values[i], y = golden->values[i];
                if (Bits(x) == Bits(y)) continue;
                if (std::abs(x - y) <= golden->tol * std::max({ 1.0, std::abs(x), std::abs(y) }))
                    continue;
                ADD_FAILURE() << name << " value " << i << ": " << x << " vs golden " << y
                              << " (tolerance " << golden->tol << ")";
                ++bad;
            }
            return;
        }
        if (golden->usesLibm && ! LibmMatchesCapture()) {
            GTEST_SKIP() << "this C library rounds sin/cos/atan2 differently from the capture; the "
                            "properties below still hold";
        }
        EXPECT_EQ(Hash(values), golden->hash) << name << ": results differ from the captured bits";
        return;
    }
    FAIL() << "no such case " << name;
}

std::vector<std::string> GoldenNames() {
    std::vector<std::string> names;
    for (const auto& op : Registry<NewLib>()) names.emplace_back(op.spec.name);
    return names;
}

INSTANTIATE_TEST_SUITE_P(Cases, LinalgGolden, ::testing::ValuesIn(GoldenNames()),
                         [](const ::testing::TestParamInfo<std::string>& info) {
                             std::string s = info.param;
                             for (char& c : s)
                                 if (c == '.') c = '_';
                             return s;
                         });

TEST(LinalgGolden, EveryCapturedCaseStillExists) {
    std::vector<std::string> known = GoldenNames();
    for (const auto& g : kGoldenOps)
        EXPECT_NE(std::find(known.begin(), known.end(), g.name), known.end())
            << g.name << " is captured but no longer run";
}

// --- layout ---------------------------------------------------------------------------------
//
// The sizes, alignment and triviality of the types are pinned at compile time in
// src/Utils/Linalg.cpp; here is what the layout means for the data.

TEST(LinalgLayout, StorageIsColumnMajorAndPacked) {
    la::Matrix3f m;
    m << 1, 2, 3, 4, 5, 6, 7, 8, 9;
    const float expected[9] = { 1, 4, 7, 2, 5, 8, 3, 6, 9 };
    for (int k = 0; k < 9; ++k) EXPECT_EQ(m.data()[k], expected[k]) << k;
    EXPECT_EQ(m(0, 2), 3.0f);
    EXPECT_EQ(m(2, 0), 7.0f);
    EXPECT_EQ(reinterpret_cast<const char*>(&m(1, 0)) - reinterpret_cast<const char*>(&m(0, 0)),
              static_cast<std::ptrdiff_t>(sizeof(float)));
    la::Matrix<double, 2, 3, la::RowMajor> r;
    r << 1, 2, 3, 4, 5, 6;
    const double rowMajor[6] = { 1, 2, 3, 4, 5, 6 };
    for (int k = 0; k < 6; ++k) EXPECT_EQ(r.data()[k], rowMajor[k]);
    const la::Matrix<double, 2, 3> asColumn       = r;
    const double                   columnMajor[6] = { 1, 4, 2, 5, 3, 6 };
    for (int k = 0; k < 6; ++k) EXPECT_EQ(asColumn.data()[k], columnMajor[k]);
}

TEST(LinalgLayout, BraceInitialisationZeroFillsAndPlainDeclarationDoesNot) {
    const la::Vector3f zero {};
    EXPECT_EQ(zero, la::Vector3f::Zero());
    const la::Matrix4d zeroMatrix {};
    EXPECT_EQ(zeroMatrix, la::Matrix4d::Zero());
    const la::Vector4f ones = la::Vector4f::Ones();
    EXPECT_EQ(ones.sum(), 4.0f);
    EXPECT_EQ(la::Vector3d::UnitY(), la::Vector3d(0, 1, 0));
    EXPECT_EQ(la::Matrix3f::Identity()(1, 1), 1.0f);
    EXPECT_EQ(la::Matrix3f::Identity()(0, 1), 0.0f);
}

TEST(LinalgLayout, VectorsBuildFromScalarsAndFromPointers) {
    const float raw[4] = { 1, 2, 3, 4 };
    EXPECT_EQ(la::Vector3f(raw), la::Vector3f(1, 2, 3));
    EXPECT_EQ(la::Vector3f { raw + 1 }, la::Vector3f(2, 3, 4));
    EXPECT_EQ(la::Vector4f(raw), la::Vector4f(1, 2, 3, 4));
    const la::Vector2d fromFloats(1.5f, 2); // the two-scalar form converts each
    EXPECT_EQ(fromFloats, la::Vector2d(1.5, 2.0));
    const la::Vector2f fromDoubles { 0.25, 0.5 };
    EXPECT_EQ(fromDoubles, la::Vector2f(0.25f, 0.5f));
    EXPECT_EQ(fromDoubles.x(), 0.25f);
    EXPECT_EQ(la::Vector4d(1, 2, 3, 4).w(), 4.0);
}

TEST(LinalgLayout, MapReadsAndWritesCallerMemory) {
    float raw[16];
    for (int k = 0; k < 16; ++k) raw[k] = static_cast<float>(k);
    const la::Matrix4f m = la::Map<const la::Matrix4f>(raw);
    EXPECT_EQ(m(0, 0), 0.0f);
    EXPECT_EQ(m(1, 0), 1.0f);
    EXPECT_EQ(m(0, 1), 4.0f);
    EXPECT_EQ(m(3, 3), 15.0f);
    la::Map<la::Matrix4f> writable(raw);
    writable(2, 1) = -1.0f;
    EXPECT_EQ(raw[6], -1.0f);
    const la::Matrix4f product = la::Map<const la::Matrix4f>(raw) * la::Matrix4f::Identity();
    EXPECT_EQ(product(2, 1), -1.0f);
    // Doubles from a float buffer go through a cast, as the uniform code does.
    const la::Matrix4d widened = la::Map<const la::Matrix4f>(raw).cast<double>();
    EXPECT_EQ(widened(2, 3), 14.0);
    EXPECT_EQ(widened(3, 2), 11.0);
}

// --- views -------------------------------------------------------------------------------

TEST(LinalgViews, BlocksWriteThroughToTheirMatrix) {
    la::Matrix4d m = la::Matrix4d::Identity();
    m.block<3, 1>(0, 3) += la::Vector3d(1, 2, 3);
    EXPECT_EQ(m(0, 3), 1.0);
    EXPECT_EQ(m(2, 3), 3.0);
    EXPECT_EQ(m(3, 3), 1.0);
    m.topRightCorner<3, 1>() *= 2.0;
    EXPECT_EQ(m(1, 3), 4.0);
    m.topLeftCorner<3, 3>() = la::Matrix3d::Constant(7.0);
    EXPECT_EQ(m(2, 2), 7.0);
    EXPECT_EQ(m(3, 2), 0.0);
    m.col(0) = la::Vector4d(9, 8, 7, 6);
    EXPECT_EQ(m(3, 0), 6.0);
    m.row(3) = la::Vector4d(1, 2, 3, 4).transpose();
    EXPECT_EQ(m(3, 1), 2.0);
    m.col(1).head<2>() = la::Vector2d(-1, -2);
    EXPECT_EQ(m(1, 1), -2.0);
    m.block<2, 1>(2, 2).setZero();
    EXPECT_EQ(m(3, 2), 0.0);
    EXPECT_EQ(m(2, 2), 0.0);
    la::Matrix3d rotation = la::Matrix3d::Identity();
    rotation.col(1) /= 4.0;
    rotation.col(2) = -rotation.col(2);
    EXPECT_EQ(rotation(1, 1), 0.25);
    EXPECT_EQ(rotation(2, 2), -1.0);
}

TEST(LinalgViews, AViewOfATemporaryIsAValueNotADanglingWindow) {
    const auto head = (la::Matrix4d::Identity() * la::Vector4d(1, 2, 3, 4)).head<3>();
    static_assert(std::is_same_v<std::remove_cv_t<decltype(head)>, la::Vector3d>);
    EXPECT_EQ(head, la::Vector3d(1, 2, 3));
    const auto block = (la::Matrix4d::Identity() * 2.0).block<2, 2>(1, 1);
    static_assert(std::is_same_v<std::remove_cv_t<decltype(block)>, la::Matrix<double, 2, 2>>);
    EXPECT_EQ(block(1, 1), 2.0);
    // A temporary view still writes through to what it looks at.
    la::Matrix4d m    = la::Matrix4d::Zero();
    la::Affine3d a    = la::Affine3d::Identity();
    a.linear().col(1) = la::Vector3d(4, 5, 6);
    a.translation()   = la::Vector3d(7, 8, 9);
    EXPECT_EQ(a.matrix()(2, 1), 6.0);
    EXPECT_EQ(a.matrix()(1, 3), 8.0);
    m.block<2, 2>(0, 0).col(1) = la::Vector2d(1, 2);
    EXPECT_EQ(m(1, 1), 2.0);
}

TEST(LinalgViews, CopyingBetweenOverlappingViewsReadsBeforeItWrites) {
    la::Matrix4d m;
    for (int k = 0; k < 16; ++k) m.data()[k] = k;
    const la::Matrix4d before = m;
    m.block<3, 3>(0, 0)       = m.block<3, 3>(1, 1);
    for (int j = 0; j < 3; ++j)
        for (int i = 0; i < 3; ++i) EXPECT_EQ(m(i, j), before(i + 1, j + 1)) << i << "," << j;
    la::Matrix3d s = before.block<3, 3>(0, 0);
    s              = s.transpose();
    EXPECT_EQ(s(0, 1), before(1, 0));
}

TEST(LinalgViews, AVectorTakesARowVectorOfTheSameLength) {
    la::Matrix3f m;
    m << 3, 0, 0, 0, 4, 0, 0, 0, 12;
    const la::Vector3f scale = m.colwise().norm();
    EXPECT_EQ(scale, la::Vector3f(3, 4, 12));
    la::Vector3f v;
    v = la::Vector3f(1, 2, 3).transpose();
    EXPECT_EQ(v, la::Vector3f(1, 2, 3));
    la::Vector4f q;
    q = la::Vector4f(1, 2, 3, 4).transpose();
    EXPECT_EQ(q.w(), 4.0f);
}

TEST(LinalgViews, ColumnsAndVectorsIterate) {
    la::Matrix3f m    = la::Matrix3f::Zero();
    float        next = 1.0f;
    for (auto column : m.colwise())
        for (auto& value : column) value = next++;
    EXPECT_EQ(m(0, 0), 1.0f);
    EXPECT_EQ(m(1, 0), 2.0f);
    EXPECT_EQ(m(0, 1), 4.0f);
    EXPECT_EQ(m(2, 2), 9.0f);
    const la::Vector4i counts(1, 2, 3, 4);
    EXPECT_EQ(std::accumulate(counts.begin(), counts.end(), 0), 10);
    la::Vector3d doubled(1, 2, 3);
    for (double& x : doubled) x *= 2;
    EXPECT_EQ(doubled, la::Vector3d(2, 4, 6));
    // A strided view iterates its own elements, not its neighbours.
    la::Matrix4f rowMajorish = la::Matrix4f::Zero();
    for (int j = 0; j < 4; ++j)
        for (int i = 0; i < 4; ++i) rowMajorish(i, j) = static_cast<float>(10 * i + j);
    auto  row = rowMajorish.row(2);
    float sum = 0;
    for (const float& x : std::as_const(row)) sum += x;
    EXPECT_EQ(sum, 20.0f + 21 + 22 + 23);
}

TEST(LinalgViews, CommaInitialiserFillsRowByRow) {
    la::Matrix<double, 2, 3> m;
    m << 1, 2, 3, 4, 5, 6;
    EXPECT_EQ(m(0, 2), 3.0);
    EXPECT_EQ(m(1, 0), 4.0);
    la::Vector3i v;
    v << 7, 8, 9;
    EXPECT_EQ(v, la::Vector3i(7, 8, 9));
}

TEST(LinalgViews, ArraysCompareAndCombineCoefficientWise) {
    const la::Vector3d a(1, 2, 3), b(1, 2, 4);
    EXPECT_FALSE((a.array() == b.array()).all());
    EXPECT_TRUE((a.array() == a.array()).all());
    const la::Vector3d shifted = ((a.array() + 0.5) * 2.0).matrix();
    EXPECT_EQ(shifted, la::Vector3d(3, 5, 7));
    const la::Vector3d scaled = (a.array() * 3.0).matrix();
    EXPECT_EQ(scaled, la::Vector3d(3, 6, 9));
    EXPECT_EQ(la::Vector3d(1, 2, 3).asDiagonal().determinant(), 6.0);
    EXPECT_EQ(la::Vector3d(1, 2, 3).asDiagonal()(1, 1), 2.0);
}

TEST(LinalgViews, MatricesStreamOneRowPerLine) {
    std::ostringstream out;
    out << la::Matrix<int, 2, 2>(la::Matrix<int, 2, 2>::Identity());
    EXPECT_EQ(out.str(), "1 0\n0 1");
    std::ostringstream row;
    row << la::Vector3i(1, 20, 3).transpose();
    EXPECT_EQ(row.str(), " 1 20  3");
}

TEST(LinalgViews, EveryMatrixTypeSharesTheGenericAccessors) {
    const auto sumAll = [](const auto& m) {
        double total = 0;
        for (la::Index c = 0; c < m.cols(); ++c)
            for (la::Index r = 0; r < m.rows(); ++r) total += static_cast<double>(m.coeff(r, c));
        return total;
    };
    la::Matrix4d m = la::Matrix4d::Constant(1.0);
    EXPECT_EQ(sumAll(m), 16.0);
    EXPECT_EQ(sumAll(m.block<2, 3>(1, 1)), 6.0);
    EXPECT_EQ(sumAll(la::Map<const la::Matrix4d>(m.data())), 16.0);
    EXPECT_EQ(sumAll(la::Vector3f(1, 2, 3)), 6.0);
}

// --- the arithmetic's meaning --------------------------------------------------------------

TEST(LinalgMath, NormalizingAZeroVectorLeavesItZero) {
    EXPECT_EQ(la::Vector3d::Zero().normalized(), la::Vector3d::Zero());
    la::Vector3d z = la::Vector3d::Zero();
    z.normalize();
    EXPECT_EQ(z, la::Vector3d::Zero());
    EXPECT_TRUE(la::Vector3d(0, 0, 0).normalized().allFinite());
    const la::Vector3d unit = la::Vector3d(3, 4, 0).normalized();
    EXPECT_DOUBLE_EQ(unit.x(), 0.6);
    EXPECT_DOUBLE_EQ(unit.y(), 0.8);
    EXPECT_DOUBLE_EQ(la::Vector3d(1, 2, 3).normalized().norm(), 1.0);
    // The drag force at rest, which is why the zero case matters.
    const la::Vector3d v = la::Vector3d::Zero();
    EXPECT_EQ(v.normalized() * (-2.0 * v.norm()), la::Vector3d::Zero());
}

TEST(LinalgMath, IsApproxIsRelativeToTheSmallerVector) {
    const la::Vector3f a(1e-3f, 2e-3f, 3e-3f);
    EXPECT_TRUE(a.isApprox(a * 1.000001f));
    EXPECT_FALSE(a.isApprox(a * 1.001f));
    EXPECT_TRUE(a.isApprox(a * 1.001f, 1e-2f));
    // Tiny vectors compare by their own scale, not an absolute epsilon.
    EXPECT_FALSE(la::Vector3f(1e-10f, 0, 0).isApprox(la::Vector3f(2e-10f, 0, 0)));
    // Against zero only an exact match passes, whatever the tolerance.
    EXPECT_FALSE(la::Vector3f(1e-10f, 0, 0).isApprox(la::Vector3f::Zero()));
    EXPECT_FALSE(la::Vector3f::Zero().isApprox(la::Vector3f(1e-10f, 0, 0), 0.5f));
    EXPECT_TRUE(la::Vector3f::Zero().isApprox(la::Vector3f::Zero()));
    // A tolerance of zero is exact equality.
    EXPECT_TRUE(la::Vector3d(1, 2, 3).isApprox(la::Vector3d(1, 2, 3), 0.0));
    EXPECT_FALSE(la::Vector3d(1, 2, 3).isApprox(la::Vector3d(1, 2, std::nextafter(3.0, 4.0)), 0.0));
    // The default tolerance follows the scalar: 1e-5 for float, 1e-12 for double.
    EXPECT_TRUE(la::Vector2f(1, 1).isApprox(la::Vector2f(1.000001f, 1)));
    EXPECT_FALSE(la::Vector2d(1, 1).isApprox(la::Vector2d(1.000001, 1)));
    EXPECT_TRUE(la::Vector2d(1, 1).isApprox(la::Vector2d(1.0 + 1e-14, 1)));
    // A NaN is never approximately anything.
    EXPECT_FALSE(la::Vector2d(NAN, 0).isApprox(la::Vector2d(NAN, 0)));
}

TEST(LinalgMath, ZeroAndIdentityPredicatesUseTheirTolerance) {
    EXPECT_TRUE(la::Vector3f(1e-6f, -1e-6f, 0).isZero());
    EXPECT_FALSE(la::Vector3f(1e-3f, 0, 0).isZero());
    EXPECT_TRUE(la::Vector3f(1e-3f, 0, 0).isZero(1e-2f));
    EXPECT_FALSE(la::Vector3f(1e-30f, 0, 0).isZero(0.0f));
    EXPECT_TRUE(la::Vector3f::Zero().isZero(0.0f));
    la::Matrix3d near = la::Matrix3d::Identity();
    near(0, 2)        = 1e-14;
    EXPECT_TRUE(near.isIdentity(1e-12));
    EXPECT_FALSE(near.isIdentity(0.0));
    near(1, 1) = 1.0 + 1e-6;
    EXPECT_FALSE(near.isIdentity(1e-12));
    EXPECT_TRUE(near.isIdentity(1e-5));
    EXPECT_FALSE(la::Matrix3d::Zero().isIdentity());
    EXPECT_TRUE(la::Vector3d(1, 2, 3).allFinite());
    EXPECT_FALSE(la::Vector3d(1, INFINITY, 3).allFinite());
    EXPECT_FALSE(la::Vector3d(1, 2, NAN).allFinite());
}

TEST(LinalgMath, ProductsAndDecompositionsFollowTheirDefinitions) {
    la::Matrix3d a;
    a << 2, 0, 1, 1, 3, 2, 0, 1, 4;
    la::Matrix3d b;
    b << 1, 2, 0, 0, 1, 1, 3, 0, 1;
    la::Matrix3d expected;
    expected << 5, 4, 1, 7, 5, 5, 12, 1, 5;
    EXPECT_EQ(a * b, expected);
    EXPECT_EQ(a * la::Vector3d(1, 1, 1), la::Vector3d(3, 6, 5));
    EXPECT_DOUBLE_EQ(a.determinant(), 2 * (12 - 2) - 0 + 1 * (1 - 0));
    for (const auto& m : { a, b }) {
        const la::Matrix3d should = m * m.inverse();
        EXPECT_TRUE(should.isIdentity(1e-14)) << should;
    }
    la::Matrix4d c = la::Matrix4d::Identity();
    c(0, 3)        = 5;
    c(1, 1)        = 2;
    c(2, 0)        = 1;
    EXPECT_DOUBLE_EQ(c.determinant(), 2.0);
    EXPECT_TRUE((c * c.inverse()).isIdentity(1e-14));
    la::Matrix2d d;
    d << 4, 7, 2, 6;
    EXPECT_DOUBLE_EQ(d.determinant(), 10.0);
    EXPECT_TRUE((d * d.inverse()).isIdentity(1e-14));
    EXPECT_EQ(la::Vector3d(1, 0, 0).cross(la::Vector3d(0, 1, 0)), la::Vector3d(0, 0, 1));
    EXPECT_EQ(la::Vector3d(1, 2, 3).dot(la::Vector3d(4, -5, 6)), 12.0);
    EXPECT_EQ(la::Vector4f(1, -2, 3, -4).cwiseAbs(), la::Vector4f(1, 2, 3, 4));
    EXPECT_EQ(la::Vector3f(1, 5, 3).cwiseMax(la::Vector3f(2, 4, 3)), la::Vector3f(2, 5, 3));
    EXPECT_EQ(la::Vector3f(1, 5, 3).cwiseMin(la::Vector3f(2, 4, 3)), la::Vector3f(1, 4, 3));
    EXPECT_EQ(la::Vector3f(1, 5, 3).maxCoeff(), 5.0f);
    EXPECT_EQ(la::Vector3f(1, 5, 3).minCoeff(), 1.0f);
}

TEST(LinalgMath, ScalarsOfAnyArithmeticTypeConvertToTheMatrixScalar) {
    const la::Vector3f v(1, 2, 3);
    EXPECT_EQ(v * 2, la::Vector3f(2, 4, 6));
    EXPECT_EQ(v * 0.5, la::Vector3f(0.5f, 1, 1.5f));
    EXPECT_EQ(2 * v, la::Vector3f(2, 4, 6));
    EXPECT_EQ(v / 2.0, la::Vector3f(0.5f, 1, 1.5f));
    EXPECT_EQ((la::Vector3d(1, 2, 3) * 2.0f)(2), 6.0);
    EXPECT_EQ(v.cast<double>() * 0.1, la::Vector3d(1 * 0.1, 2 * 0.1, 3 * 0.1));
    EXPECT_EQ(la::Vector3f(1.9f, -1.9f, 3.0f).cast<int>(), la::Vector3i(1, -1, 3));
}

// --- rotations and transforms --------------------------------------------------------------

constexpr double kHalfPi = 1.5707963267948966;

TEST(LinalgGeometry, AnAngleAxisIsARightHandedRotation) {
    const la::Matrix3d r = la::AngleAxisd(kHalfPi, la::Vector3d::UnitZ()).toRotationMatrix();
    EXPECT_LT((r * la::Vector3d(1, 0, 0) - la::Vector3d(0, 1, 0)).norm(), 1e-15);
    EXPECT_LT((r * la::Vector3d(0, 1, 0) - la::Vector3d(-1, 0, 0)).norm(), 1e-15);
    const la::Vector3d v = la::AngleAxisd(kHalfPi, la::Vector3d::UnitX()) * la::Vector3d(0, 1, 0);
    EXPECT_LT((v - la::Vector3d(0, 0, 1)).norm(), 1e-15);
    const la::Matrix3d any =
        la::AngleAxisd(0.7, la::Vector3d(1, 2, 3).normalized()).toRotationMatrix();
    EXPECT_TRUE((any * any.transpose()).isIdentity(1e-14));
    EXPECT_NEAR(any.determinant(), 1.0, 1e-14);
}

TEST(LinalgGeometry, AQuaternionIsStoredXyzwAndBuiltWxyz) {
    const la::Quaterniond q(1.0, 2.0, 3.0, 4.0);
    EXPECT_EQ(q.w(), 1.0);
    EXPECT_EQ(q.x(), 2.0);
    EXPECT_EQ(q.y(), 3.0);
    EXPECT_EQ(q.z(), 4.0);
    EXPECT_EQ(q.coeffs(), la::Vector4d(2, 3, 4, 1));
    EXPECT_EQ(q.vec(), la::Vector3d(2, 3, 4));
    EXPECT_EQ(la::Quaterniond::Identity().coeffs(), la::Vector4d(0, 0, 0, 1));
    const la::Quaterniond c = q.conjugate();
    EXPECT_EQ(c.coeffs(), la::Vector4d(-2, -3, -4, 1));
    const la::Quaterniond fromAxis(la::AngleAxisd(kHalfPi, la::Vector3d::UnitZ()));
    EXPECT_NEAR(fromAxis.w(), std::sqrt(0.5), 1e-15);
    EXPECT_NEAR(fromAxis.z(), std::sqrt(0.5), 1e-15);
    EXPECT_EQ(fromAxis.x(), 0.0);
    // The Hamilton product composes rotations: the right one acts first.
    const la::Quaterniond both = la::Quaterniond(la::AngleAxisd(kHalfPi, la::Vector3d::UnitZ())) *
                                 la::Quaterniond(la::AngleAxisd(kHalfPi, la::Vector3d::UnitX()));
    const la::Matrix3d expected =
        la::AngleAxisd(kHalfPi, la::Vector3d::UnitZ()).toRotationMatrix() *
        la::AngleAxisd(kHalfPi, la::Vector3d::UnitX()).toRotationMatrix();
    EXPECT_TRUE(both.toRotationMatrix().isApprox(expected, 1e-14));
    EXPECT_TRUE(la::Quaterniond(expected).toRotationMatrix().isApprox(expected, 1e-14));
}

TEST(LinalgGeometry, AQuaternionFromAMatrixTakesTheRightBranch) {
    // A half turn about each axis puts the largest diagonal entry on a different one.
    for (int axis = 0; axis < 3; ++axis) {
        la::Vector3d u          = la::Vector3d::Zero();
        u(axis)                 = 1.0;
        const la::Matrix3d    r = la::AngleAxisd(3.14159265358979323846, u).toRotationMatrix();
        const la::Quaterniond q(r);
        EXPECT_NEAR(std::abs(q.coeffs()(axis)), 1.0, 1e-15) << axis;
        EXPECT_TRUE(q.toRotationMatrix().isApprox(r, 1e-14)) << axis;
    }
    const la::Matrix3d identity = la::Matrix3d::Identity();
    EXPECT_EQ(la::Quaterniond(identity).coeffs(), la::Vector4d(0, 0, 0, 1));
}

TEST(LinalgGeometry, SlerpInterpolatesTheShorterArc) {
    const la::Quaterniond a = la::Quaterniond::Identity();
    const la::Quaterniond b(la::AngleAxisd(kHalfPi, la::Vector3d::UnitZ()));
    EXPECT_TRUE(a.slerp(0.0, b).coeffs().isApprox(a.coeffs(), 1e-15));
    EXPECT_TRUE(a.slerp(1.0, b).coeffs().isApprox(b.coeffs(), 1e-15));
    const la::Quaterniond mid = a.slerp(0.5, b);
    EXPECT_TRUE(mid.coeffs().isApprox(
        la::Quaterniond(la::AngleAxisd(kHalfPi / 2.0, la::Vector3d::UnitZ())).coeffs(), 1e-15));
    EXPECT_NEAR(mid.norm(), 1.0, 1e-15);
    // The same rotation with the opposite sign is not a long way round.
    const la::Quaterniond negated(-b.w(), -b.x(), -b.y(), -b.z());
    EXPECT_TRUE(a.slerp(0.5, negated).toRotationMatrix().isApprox(mid.toRotationMatrix(), 1e-14));
    // Nearly parallel quaternions interpolate without dividing by a vanishing sine.
    const la::Quaterniond close   = la::Quaterniond(la::AngleAxisd(1e-9, la::Vector3d::UnitX()));
    const la::Quaterniond between = a.slerp(0.25, close);
    EXPECT_TRUE(between.coeffs().allFinite());
    EXPECT_NEAR(between.x(), 0.25 * close.x(), 1e-20);
    EXPECT_TRUE(a.slerp(0.3, a).coeffs().isApprox(a.coeffs(), 1e-15));
}

TEST(LinalgGeometry, PreOperationsActAfterAndPostOperationsActBefore) {
    const la::Vector3d t(1, 2, 3), s(2, 3, 4);
    // T' = N * T for the pre- forms.
    la::Affine3d pre = la::Affine3d::Identity();
    pre.pretranslate(t);
    pre.prescale(s); // the scale acts after the translation, so it scales it too
    EXPECT_EQ(pre.translation(), la::Vector3d(2, 6, 12));
    EXPECT_EQ(pre.linear(), la::Matrix3d(s.asDiagonal()));
    // T' = T * N for the others.
    la::Affine3d post = la::Affine3d::Identity();
    post.translate(t);
    post.scale(s); // the scale acts before the translation: the translation stays
    EXPECT_EQ(post.translation(), t);
    EXPECT_EQ(post.linear(), la::Matrix3d(s.asDiagonal()));
    // Rotation: R after (prerotate) or before (rotate) a translation.
    const la::AngleAxisd turn(kHalfPi, la::Vector3d::UnitZ());
    la::Affine3d         a = la::Affine3d::Identity();
    a.pretranslate(la::Vector3d(1, 0, 0));
    a.prerotate(turn); // the translation is rotated too
    EXPECT_LT((a.translation() - la::Vector3d(0, 1, 0)).norm(), 1e-15);
    la::Affine3d b = la::Affine3d::Identity();
    b.pretranslate(la::Vector3d(1, 0, 0));
    b.rotate(turn); // the translation is untouched
    EXPECT_EQ(b.translation(), la::Vector3d(1, 0, 0));
    EXPECT_LT((b.linear() - turn.toRotationMatrix()).norm(), 1e-15);
    // They are the matrix products they say they are.
    la::Affine3d c = la::Affine3d::Identity();
    c.prescale(s);
    c.prerotate(turn);
    c.pretranslate(t);
    la::Matrix4d expected           = la::Matrix4d::Identity();
    expected.topLeftCorner<3, 3>()  = turn.toRotationMatrix() * la::Matrix3d(s.asDiagonal());
    expected.topRightCorner<3, 1>() = t;
    EXPECT_LT((c.matrix() - expected).norm(), 1e-14);
    // And a point goes through linear then translation.
    EXPECT_LT((c * la::Vector3d(1, 1, 1) - (expected * la::Vector4d(1, 1, 1, 1)).head<3>()).norm(),
              1e-14);
    // Composition and inversion.
    const la::Affine3d product = c * c.inverse();
    EXPECT_TRUE(product.matrix().isApprox(la::Matrix4d::Identity(), 1e-13));
    EXPECT_TRUE((c * c).matrix().isApprox(c.matrix() * c.matrix(), 1e-14));
    EXPECT_EQ(c.matrix()(3, 0), 0.0);
    EXPECT_EQ(c.matrix()(3, 3), 1.0);
    // Built from a translation, a scaling or a matrix.
    EXPECT_EQ(la::Affine3d(la::Translation3d(1, 2, 3)).translation(), la::Vector3d(1, 2, 3));
    EXPECT_EQ(la::Affine3d(la::Scaling(2.0, 3.0, 4.0)).matrix()(2, 2), 4.0);
    EXPECT_EQ(la::Affine3d(expected).matrix(), expected);
    la::Affine3d withTranslation = la::Affine3d::Identity();
    withTranslation *= la::Translation3d(la::Vector3d(0, 5, 0));
    EXPECT_EQ(withTranslation.translation(), la::Vector3d(0, 5, 0));
    // A product with a plain matrix leaves the transform's own bottom row out of it.
    const la::Matrix4d viaMatrix = c * la::Matrix4d::Identity();
    EXPECT_EQ(viaMatrix, c.matrix());
}

TEST(LinalgGeometry, ProjectiveScalesAndTranslatesTheWholeMatrix) {
    la::Projective3d p = la::Projective3d::Identity();
    p(3, 2)            = 1.0;
    p(3, 3)            = 0.0;
    p.scale(la::Vector3d(1, 1, -1)); // columns scale, the bottom row with them
    EXPECT_EQ(p(3, 2), -1.0);
    p.prescale(la::Vector3d(2, 2, 2)); // the first three rows scale
    EXPECT_EQ(p(0, 0), 2.0);
    EXPECT_EQ(p(3, 2), -1.0);
    la::Projective3d q = la::Projective3d::Identity();
    q(3, 0)            = 5.0;
    q.pretranslate(la::Vector3d(1, 0, 0)); // T(v) * M adds v times the bottom row
    EXPECT_EQ(q(0, 0), 6.0);
    q.translate(la::Vector3d(0, 0, 2)); // M * T(v): the last column takes M * (v, 0)
    EXPECT_EQ(q(2, 3), 2.0);
}

// A rotation about one axis, spelled out.
la::Matrix3d AxisRotation(int axis, double angle) {
    la::Vector3d u = la::Vector3d::Zero();
    u(axis)        = 1.0;
    return la::AngleAxisd(angle, u).toRotationMatrix();
}

TEST(LinalgGeometry, EulerAnglesRebuildTheRotationInTheRangesDocumented) {
    Rng          rng(7);
    const double pi           = 3.14159265358979323846;
    const int    orders[6][3] = { { 0, 1, 2 }, { 0, 2, 1 }, { 1, 0, 2 },
                                  { 1, 2, 0 }, { 2, 0, 1 }, { 2, 1, 0 } };
    for (int trial = 0; trial < 3000; ++trial) {
        const la::Matrix3d m = RandomRotation<la::Matrix3d>(rng);
        for (const auto& order : orders) {
            const la::Vector3d e = m.eulerAngles(order[0], order[1], order[2]);
            EXPECT_GE(e(0), 0.0);
            EXPECT_LE(e(0), pi);
            EXPECT_GE(e(1), -pi);
            EXPECT_LE(e(1), pi);
            EXPECT_GE(e(2), -pi);
            EXPECT_LE(e(2), pi);
            const la::Matrix3d back = AxisRotation(order[0], e(0)) * AxisRotation(order[1], e(1)) *
                                      AxisRotation(order[2], e(2));
            EXPECT_LT((back - m).cwiseAbs().maxCoeff(), 1e-12)
                << "order " << order[0] << order[1] << order[2] << " trial " << trial;
        }
    }
}

TEST(LinalgGeometry, EulerAnglesRebuildARotationAtTheGimbalPole) {
    const double pole[] = { 1.5707963267948966, -1.5707963267948966 };
    const double off[]  = { 0.0, 1e-12, -1e-12, 1e-7, -1e-7 };
    for (double p : pole) {
        for (double o : off) {
            const la::Matrix3d m =
                AxisRotation(2, 0.4) * AxisRotation(1, p + o) * AxisRotation(0, -0.9);
            const la::Vector3d e = m.eulerAngles(2, 1, 0);
            EXPECT_TRUE(e.allFinite());
            const la::Matrix3d back =
                AxisRotation(2, e(0)) * AxisRotation(1, e(1)) * AxisRotation(0, e(2));
            EXPECT_LT((back - m).cwiseAbs().maxCoeff(), 1e-6) << p << " " << o;
        }
    }
}

TEST(LinalgGeometry, EulerAnglesOfASimpleRotationAreThoseAngles) {
    const la::Matrix3d m = AxisRotation(2, 0.5) * AxisRotation(1, -0.25) * AxisRotation(0, 1.25);
    const la::Vector3d e = m.eulerAngles(2, 1, 0);
    EXPECT_NEAR(e(0), 0.5, 1e-15);
    EXPECT_NEAR(e(1), -0.25, 1e-15);
    EXPECT_NEAR(e(2), 1.25, 1e-15);
    // A negative first angle comes back as the equivalent triple with it in [0, pi].
    const la::Matrix3d n = AxisRotation(2, -0.5) * AxisRotation(1, 0.25) * AxisRotation(0, 1.25);
    const la::Vector3d f = n.eulerAngles(2, 1, 0);
    EXPECT_GE(f(0), 0.0);
    const la::Matrix3d back = AxisRotation(2, f(0)) * AxisRotation(1, f(1)) * AxisRotation(0, f(2));
    EXPECT_LT((back - n).cwiseAbs().maxCoeff(), 1e-14);
}

TEST(LinalgGeometry, FullPivLuTellsInvertibleFromSingularAndInverts) {
    la::Matrix4d m = la::Matrix4d::Identity();
    m(0, 1)        = 2;
    m(1, 3)        = -3;
    m(2, 0)        = 0.5;
    m(3, 2)        = 4;
    const la::FullPivLU<la::Matrix4d> lu(m);
    EXPECT_TRUE(lu.isInvertible());
    EXPECT_EQ(lu.rank(), 4);
    EXPECT_TRUE((lu.inverse() * m).isIdentity(1e-14));
    EXPECT_TRUE((m * lu.inverse()).isIdentity(1e-14));
    la::Matrix4d dup = m;
    dup.col(2)       = dup.col(1);
    EXPECT_FALSE(la::FullPivLU<la::Matrix4d>(dup).isInvertible());
    EXPECT_EQ(la::FullPivLU<la::Matrix4d>(dup).rank(), 3);
    EXPECT_FALSE(la::FullPivLU<la::Matrix4d>(la::Matrix4d::Zero()).isInvertible());
    EXPECT_EQ(la::FullPivLU<la::Matrix4d>(la::Matrix4d::Zero()).rank(), 0);
    // A pivot below the threshold relative to the biggest counts as zero.
    la::Matrix4d tiny = la::Matrix4d::Identity();
    tiny(2, 2)        = 1e-17;
    EXPECT_FALSE(la::FullPivLU<la::Matrix4d>(tiny).isInvertible());
    tiny(2, 2) = 1e-9;
    EXPECT_TRUE(la::FullPivLU<la::Matrix4d>(tiny).isInvertible());
    // A permutation needs the pivoting.
    la::Matrix4d perm = la::Matrix4d::Zero();
    perm(0, 2)        = 1;
    perm(1, 0)        = 1;
    perm(2, 3)        = 1;
    perm(3, 1)        = 1;
    EXPECT_TRUE(la::FullPivLU<la::Matrix4d>(perm).isInvertible());
    EXPECT_EQ(la::FullPivLU<la::Matrix4d>(perm).inverse(), perm.transpose());
}

// A layer scaled to nothing makes its model matrix singular. Its inverse, which the
// shader inverse uniforms and the mouse-to-local mapping take, divides by an exactly zero
// determinant and is not finite, and the LU, which the hit tests use, reports it singular.
TEST(LinalgMath, AModelMatrixScaledToNothingHasANonFiniteInverseAndASingularLu) {
    for (int axis = 0; axis < 3; ++axis) {
        la::Vector3d scale(2, 3, 4);
        scale[axis] = 0;
        la::Affine3d model = la::Affine3d::Identity();
        model.prescale(scale);
        model.pretranslate(la::Vector3d(5, -1, 7));
        const la::Matrix4d m = model.matrix();
        EXPECT_EQ(m.determinant(), 0.0) << "axis " << axis;
        EXPECT_FALSE(m.inverse().allFinite()) << "axis " << axis;
        EXPECT_FALSE(la::FullPivLU<la::Matrix4d>(m).isInvertible()) << "axis " << axis;
        EXPECT_FALSE(model.inverse().matrix().allFinite()) << "axis " << axis;
    }
}

TEST(LinalgGeometry, CameraMatricesMapTheirVolumesToTheClipRange) {
    const la::Matrix4d o    = la::Ortho(-4, 6, -2, 2, 1, 11);
    const auto         clip = [&](la::Vector3d p) {
        return (o * la::Vector4d(p.x(), p.y(), p.z(), 1)).eval();
    };
    // Looks down -Z; depth runs 0 at the near plane to 1 at the far one.
    EXPECT_NEAR(clip({ -4, -2, -1 }).x(), -1.0, 1e-15);
    EXPECT_NEAR(clip({ 6, 2, -1 }).y(), 1.0, 1e-15);
    EXPECT_NEAR(clip({ 1, 0, -1 }).z(), 0.0, 1e-15);
    EXPECT_NEAR(clip({ 1, 0, -11 }).z(), 1.0, 1e-15);
    EXPECT_EQ(clip({ 1, 0, -5 }).w(), 1.0);
    const la::Matrix4d view =
        la::LookAt(la::Vector3d(0, 0, 5), la::Vector3d(0, 0, 0), la::Vector3d(0, 1, 0));
    const la::Vector4d eyeSpace = view * la::Vector4d(0, 0, 0, 1);
    EXPECT_NEAR(eyeSpace.z(), -5.0, 1e-15);
    EXPECT_NEAR(eyeSpace.x(), 0.0, 1e-15);
    // The rotation part's columns are the camera's axes: +Z points from the target to the eye.
    const la::Matrix4d shifted =
        la::LookAt(la::Vector3d(3, 0, 0), la::Vector3d(0, 0, 0), la::Vector3d(0, 1, 0));
    EXPECT_EQ(shifted.col(2).head<3>(), la::Vector3d(1, 0, 0));
    EXPECT_EQ(shifted.col(1).head<3>(), la::Vector3d(0, 1, 0));
    EXPECT_EQ(shifted.col(0).head<3>(), la::Vector3d(0, 0, -1));
    // A perspective projection keeps the centre line and divides by depth.
    const la::Matrix4d p   = la::Perspective(1.0, 1.5, 0.1, 100.0);
    const la::Vector4d far = p * la::Vector4d(0, 0, -100, 1);
    EXPECT_NEAR(far.x(), 0.0, 1e-15);
    EXPECT_TRUE(far.allFinite());
    EXPECT_NEAR(la::Radians(180.0), 3.14159265358979323846, 1e-15);
    EXPECT_NEAR(la::Radians(90.0), kHalfPi, 1e-15);
}

TEST(LinalgGeometry, DenseMatricesRoundTripThroughACast) {
    la::Matrix4f f;
    for (int k = 0; k < 16; ++k) f.data()[k] = static_cast<float>(k) * 0.25f;
    const la::Matrix4d d    = f.cast<double>();
    const la::Matrix4f back = d.cast<float>();
    EXPECT_EQ(back, f);
    EXPECT_EQ(la::Vector3d(1.9, -1.9, 7.5).cast<int>(), la::Vector3i(1, -1, 7));
}

} // namespace
