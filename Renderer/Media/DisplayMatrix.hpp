// The 3x3 display matrix an ISO-BMFF `tkhd` box carries (and that FFmpeg exposes
// as its display-matrix side data): nine int32 values in the order
// a b u / c d v / x y w, where a b c d x y are 16.16 fixed point and u v w are
// 2.30. A video stream reports it as stored; this header only classifies it.
#pragma once

#include <array>
#include <cstdint>
#include <optional>

namespace wallpaper::media
{

using DisplayMatrix = std::array<std::int32_t, 9>;

inline constexpr DisplayMatrix kIdentityDisplayMatrix { 65536, 0, 0, 0, 65536, 0, 0, 0, 1 << 30 };

/// The eight ways a picture can be rotated by quarter turns and mirrored. Named
/// by the (a b c d) coefficients: identity 1 0 0 1, rotate90 0 1 -1 0,
/// rotate180 -1 0 0 -1, rotate270 0 -1 1 0, mirrorX -1 0 0 1, mirrorY 1 0 0 -1,
/// transpose 0 1 1 0, transverse 0 -1 -1 0.
enum class Orientation : std::uint8_t {
    Identity,
    Rotate90,
    Rotate180,
    Rotate270,
    MirrorX,
    MirrorY,
    Transpose,
    Transverse,
};

/// The orientation `matrix` encodes, or nullopt when it is not exactly one of the
/// eight (a scale, a shear, a translation-only matrix with a zero row, or a
/// projective term). Translation (x, y) is ignored: it only places the image.
std::optional<Orientation> ClassifyDisplayMatrix(const DisplayMatrix& matrix);

/// True when the orientation exchanges the horizontal and vertical axes (a
/// quarter turn, transpose or transverse), so displayed width is coded height.
bool SwapsAxes(Orientation orientation);

} // namespace wallpaper::media
