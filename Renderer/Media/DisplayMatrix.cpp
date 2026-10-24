#include "Media/DisplayMatrix.hpp"

namespace wallpaper::media
{
namespace
{

// -1, 0 or 1 when `value` is exactly that multiple of the matrix's unit (1.0 in
// 16.16 once divided by the 2.30 homogeneous term), otherwise 2.
int UnitOf(std::int32_t value, std::int64_t homogeneous)
{
    if (value == 0) return 0;
    const std::int64_t scaled = static_cast<std::int64_t>(value) * (std::int64_t { 1 } << 30);
    const std::int64_t unit   = std::int64_t { 65536 } * homogeneous;
    if (scaled == unit) return 1;
    if (scaled == -unit) return -1;
    return 2;
}

} // namespace

std::optional<Orientation> ClassifyDisplayMatrix(const DisplayMatrix& matrix)
{
    // u and v must be 0 (no perspective) and w positive.
    if (matrix[2] != 0 || matrix[5] != 0 || matrix[8] <= 0) return std::nullopt;
    const std::int64_t w = matrix[8];
    const int a = UnitOf(matrix[0], w);
    const int b = UnitOf(matrix[1], w);
    const int c = UnitOf(matrix[3], w);
    const int d = UnitOf(matrix[4], w);
    if (a == 2 || b == 2 || c == 2 || d == 2) return std::nullopt;
    if (a == 1 && b == 0 && c == 0 && d == 1) return Orientation::Identity;
    if (a == 0 && b == 1 && c == -1 && d == 0) return Orientation::Rotate90;
    if (a == -1 && b == 0 && c == 0 && d == -1) return Orientation::Rotate180;
    if (a == 0 && b == -1 && c == 1 && d == 0) return Orientation::Rotate270;
    if (a == -1 && b == 0 && c == 0 && d == 1) return Orientation::MirrorX;
    if (a == 1 && b == 0 && c == 0 && d == -1) return Orientation::MirrorY;
    if (a == 0 && b == 1 && c == 1 && d == 0) return Orientation::Transpose;
    if (a == 0 && b == -1 && c == -1 && d == 0) return Orientation::Transverse;
    return std::nullopt;
}

bool SwapsAxes(Orientation orientation)
{
    switch (orientation) {
    case Orientation::Rotate90:
    case Orientation::Rotate270:
    case Orientation::Transpose:
    case Orientation::Transverse: return true;
    case Orientation::Identity:
    case Orientation::Rotate180:
    case Orientation::MirrorX:
    case Orientation::MirrorY: return false;
    }
    return false;
}

} // namespace wallpaper::media
