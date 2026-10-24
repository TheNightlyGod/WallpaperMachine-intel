// Builds Utils/Linalg.hpp under the engine's warning flags on its own, and pins the
// layout the rest of the engine relies on. The library is header-only; this file holds no
// code of its own.
#include "Utils/Linalg.hpp"

#include <type_traits>

namespace wallpaper::linalg
{

// A vector or matrix is exactly its scalars, column by column: `data()` goes straight to
// a GPU uniform upload or the script bridge, and a `std::vector` of them is one block of
// scalars. Nothing may add padding, alignment or a hidden member.
static_assert(sizeof(Vector2f) == 8 && sizeof(Vector3f) == 12 && sizeof(Vector4f) == 16);
static_assert(sizeof(Vector2d) == 16 && sizeof(Vector3d) == 24 && sizeof(Vector4d) == 32);
static_assert(sizeof(Vector2i) == 8 && sizeof(Vector3i) == 12 && sizeof(Vector4i) == 16);
static_assert(sizeof(Matrix3f) == 36 && sizeof(Matrix4f) == 64);
static_assert(sizeof(Matrix3d) == 72 && sizeof(Matrix4d) == 128);
static_assert(sizeof(Affine3f) == 64 && sizeof(Affine3d) == 128);
static_assert(sizeof(Quaternionf) == 16 && sizeof(Quaterniond) == 32);
static_assert(alignof(Vector3f) == alignof(float) && alignof(Matrix4d) == alignof(double));
static_assert(std::is_standard_layout_v<Matrix4d> && std::is_standard_layout_v<Vector3f>);
static_assert(std::is_trivially_copyable_v<Matrix4f> && std::is_trivially_copyable_v<Vector3f> &&
              std::is_trivially_copyable_v<Affine3f> && std::is_trivially_copyable_v<Quaterniond>);
static_assert(std::is_trivially_default_constructible_v<Vector3f> &&
              std::is_trivially_default_constructible_v<Matrix4d>);
static_assert(std::is_nothrow_move_constructible_v<Matrix4f>);

// Compiling every member of the engine's types here, used or not, keeps a warning or an
// error in a rarely called one from waiting for its first caller.
template class DenseBase<Matrix<float, 2, 1>>;
template class DenseBase<Matrix<float, 3, 1>>;
template class DenseBase<Matrix<float, 4, 1>>;
template class DenseBase<Matrix<double, 2, 1>>;
template class DenseBase<Matrix<double, 3, 1>>;
template class DenseBase<Matrix<double, 4, 1>>;
template class DenseBase<Matrix<int, 2, 1>>;
template class DenseBase<Matrix<int, 3, 1>>;
template class DenseBase<Matrix<int, 4, 1>>;
template class DenseBase<Matrix<float, 3, 3>>;
template class DenseBase<Matrix<float, 4, 4>>;
template class DenseBase<Matrix<double, 3, 3>>;
template class DenseBase<Matrix<double, 4, 4>>;
template class Matrix<float, 2, 1>;
template class Matrix<float, 3, 1>;
template class Matrix<float, 4, 1>;
template class Matrix<double, 2, 1>;
template class Matrix<double, 3, 1>;
template class Matrix<double, 4, 1>;
template class Matrix<int, 2, 1>;
template class Matrix<int, 3, 1>;
template class Matrix<int, 4, 1>;
template class Matrix<float, 3, 3>;
template class Matrix<float, 4, 4>;
template class Matrix<double, 3, 3>;
template class Matrix<double, 4, 4>;
template class Block<double, 3, 3>;
template class Block<const double, 3, 1>;
template class Block<float, 3, 1>;
template class AngleAxis<float>;
template class AngleAxis<double>;
template class Quaternion<float>;
template class Quaternion<double>;
template class Translation<double>;
template class Transform<float, 3, Affine>;
template class Transform<double, 3, Affine>;
template class Transform<double, 3, Projective>;
template class FullPivLU<Matrix<double, 4, 4>>;

} // namespace wallpaper::linalg
