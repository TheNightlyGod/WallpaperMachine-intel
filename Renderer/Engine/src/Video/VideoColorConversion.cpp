#include "Video/VideoColorConversion.hpp"

#include <algorithm>
#include <array>
#include <cmath>

namespace wallpaper::video
{
namespace
{

/// Derived from the luma coefficients Kr/Kb of each matrix:
///   r_cr = 2(1 - Kr), b_cb = 2(1 - Kb),
///   g_cb = -2 Kb (1 - Kb) / Kg, g_cr = -2 Kr (1 - Kr) / Kg.
struct MatrixCoefficients {
    float r_cr;
    float g_cb;
    float g_cr;
    float b_cb;
};

constexpr MatrixCoefficients CoefficientsFor(YuvMatrix matrix)
{
    switch (matrix) {
    case YuvMatrix::Bt709:
        return { 1.5748f, -0.187324f, -0.468124f, 1.8556f };
    case YuvMatrix::Bt2020NonConstantLuminance:
        return { 1.4746f, -0.164553f, -0.571353f, 1.8814f };
    case YuvMatrix::Bt601:
        break;
    }
    return { 1.402f, -0.344136f, -0.714136f, 1.772f };
}

/// CIE 1931 xy chromaticities of a set of primaries and its white point. All
/// three sets here use D65.
struct Chromaticities {
    double red[2];
    double green[2];
    double blue[2];
    double white[2];
};

constexpr Chromaticities ChromaticitiesOf(ColorPrimaries primaries)
{
    switch (primaries) {
    case ColorPrimaries::Bt2020:
        return { { 0.708, 0.292 }, { 0.170, 0.797 }, { 0.131, 0.046 }, { 0.3127, 0.3290 } };
    case ColorPrimaries::P3D65:
        return { { 0.680, 0.320 }, { 0.265, 0.690 }, { 0.150, 0.060 }, { 0.3127, 0.3290 } };
    case ColorPrimaries::Bt709:
        break;
    }
    return { { 0.640, 0.330 }, { 0.300, 0.600 }, { 0.150, 0.060 }, { 0.3127, 0.3290 } };
}

using Matrix3 = std::array<std::array<double, 3>, 3>;

Matrix3 Inverse(const Matrix3& m)
{
    const double a = m[0][0], b = m[0][1], c = m[0][2];
    const double d = m[1][0], e = m[1][1], f = m[1][2];
    const double g = m[2][0], h = m[2][1], i = m[2][2];
    const double determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    const double s = 1.0 / determinant;
    return {{
        { (e * i - f * h) * s, (c * h - b * i) * s, (b * f - c * e) * s },
        { (f * g - d * i) * s, (a * i - c * g) * s, (c * d - a * f) * s },
        { (d * h - e * g) * s, (b * g - a * h) * s, (a * e - b * d) * s },
    }};
}

Matrix3 Multiply(const Matrix3& l, const Matrix3& r)
{
    Matrix3 out {};
    for (size_t row = 0; row < 3; ++row)
        for (size_t column = 0; column < 3; ++column)
            for (size_t k = 0; k < 3; ++k) out[row][column] += l[row][k] * r[k][column];
    return out;
}

/// Linear RGB of `primaries` to CIE XYZ: the primaries' own columns, scaled so
/// that RGB (1, 1, 1) lands on the white point.
Matrix3 RgbToXyz(ColorPrimaries primaries)
{
    const Chromaticities c = ChromaticitiesOf(primaries);
    const auto xyz = [](const double (&xy)[2]) {
        return std::array<double, 3> { xy[0] / xy[1], 1.0, (1.0 - xy[0] - xy[1]) / xy[1] };
    };
    const auto r = xyz(c.red);
    const auto g = xyz(c.green);
    const auto b = xyz(c.blue);
    const auto w = xyz(c.white);
    const Matrix3 columns {{ { r[0], g[0], b[0] }, { r[1], g[1], b[1] }, { r[2], g[2], b[2] } }};
    const Matrix3 inverse = Inverse(columns);
    std::array<double, 3> scale {};
    for (size_t row = 0; row < 3; ++row) {
        scale[row] = inverse[row][0] * w[0] + inverse[row][1] * w[1] + inverse[row][2] * w[2];
    }
    Matrix3 out {};
    for (size_t row = 0; row < 3; ++row)
        for (size_t column = 0; column < 3; ++column) out[row][column] = columns[row][column] * scale[column];
    return out;
}

uint8_t QuantizeUnitToCode(float value)
{
    const float clamped = std::clamp(value, 0.0f, 1.0f);
    return static_cast<uint8_t>(std::lround(clamped * 255.0f));
}

} // namespace

YuvMatrix InferYuvMatrix(uint32_t width, uint32_t height)
{
    // Anything at or below standard-definition height is treated as BT.601;
    // everything larger as BT.709. Width guards anamorphic SD sources whose
    // height alone would look like HD.
    const bool standard_definition = height <= 576 && width <= 1024;
    return standard_definition ? YuvMatrix::Bt601 : YuvMatrix::Bt709;
}

YuvColorParams MakeYuvColorParams(const YuvColorDescription& description)
{
    const uint32_t bit_depth = std::clamp(description.bit_depth, 8u, 16u);
    const float    maximum_code = static_cast<float>((1u << bit_depth) - 1u);
    // Studio-swing footroom and the chroma midpoint scale with bit depth.
    const float    depth_scale = static_cast<float>(1u << (bit_depth - 8u));
    const float    chroma_midpoint = 128.0f * depth_scale;

    const MatrixCoefficients coefficients = CoefficientsFor(description.matrix);
    YuvColorParams params {};
    params.r_cr = coefficients.r_cr;
    params.g_cb = coefficients.g_cb;
    params.g_cr = coefficients.g_cr;
    params.b_cb = coefficients.b_cb;
    params.chroma_offset = chroma_midpoint / maximum_code;

    if (description.range == YuvRange::Full) {
        params.y_offset = 0.0f;
        params.y_scale = 1.0f;
        // Full-swing chroma still centres on the midpoint, but spans the whole
        // code range rather than 224 code values.
        params.chroma_scale = maximum_code / (255.0f * depth_scale);
        return params;
    }

    params.y_offset = 16.0f * depth_scale / maximum_code;
    params.y_scale = maximum_code / (219.0f * depth_scale);
    // The chroma excursion is 224 code values, not 219 and not the full range:
    // reusing the luma scale, or treating chroma as `sample - 0.5`, desaturates
    // and shifts every limited-range frame.
    params.chroma_scale = maximum_code / (224.0f * depth_scale);
    return params;
}

HdrConversionParams MakeHdrConversionParams(const YuvColorDescription& description)
{
    HdrConversionParams params {};
    params.transfer = static_cast<uint32_t>(description.transfer);
    const float stated = description.peak_nits > 0.0f ? description.peak_nits : kDefaultHdrPeakNits;
    params.source_peak_nits = std::min(stated, kMaximumHdrPeakNits);
    params.reference_white_nits = kReferenceWhiteNits;
    if (description.primaries != ColorPrimaries::Bt709) {
        params.convert_gamut = 1;
        const Matrix3 conversion =
            Multiply(Inverse(RgbToXyz(ColorPrimaries::Bt709)), RgbToXyz(description.primaries));
        for (size_t row = 0; row < 3; ++row)
            for (size_t column = 0; column < 3; ++column)
                params.gamut[row][column] = static_cast<float>(conversion[row][column]);
    }
    return params;
}

Rgb8 ConvertYuvCodeToRgb8(const YuvColorParams& params,
                          uint8_t luma_code,
                          uint8_t cb_code,
                          uint8_t cr_code)
{
    const float luma =
        std::clamp((static_cast<float>(luma_code) / 255.0f - params.y_offset) * params.y_scale,
                   0.0f, 1.0f);
    const float cb =
        (static_cast<float>(cb_code) / 255.0f - params.chroma_offset) * params.chroma_scale;
    const float cr =
        (static_cast<float>(cr_code) / 255.0f - params.chroma_offset) * params.chroma_scale;

    return Rgb8 {
        .red = QuantizeUnitToCode(luma + params.r_cr * cr),
        .green = QuantizeUnitToCode(luma + params.g_cb * cb + params.g_cr * cr),
        .blue = QuantizeUnitToCode(luma + params.b_cb * cb),
    };
}

const char* YuvMatrixName(YuvMatrix matrix)
{
    switch (matrix) {
    case YuvMatrix::Bt601: return "BT.601";
    case YuvMatrix::Bt709: return "BT.709";
    case YuvMatrix::Bt2020NonConstantLuminance: return "BT.2020 NCL";
    }
    return "unknown";
}

const char* YuvRangeName(YuvRange range)
{
    return range == YuvRange::Full ? "full" : "limited";
}

} // namespace wallpaper::video
