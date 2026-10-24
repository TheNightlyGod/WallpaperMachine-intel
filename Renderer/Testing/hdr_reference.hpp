// A CPU reference for what the 10-bit video conversion kernel computes, for the
// tests that compare the GPU's picture against it.
//
// Written from the standards, not from the kernel, so that the two can disagree:
//   * ITU-R BT.709 / BT.2020 for the YCbCr matrices (the luma weights are all it
//     needs; the rest follows from them) and BT.2100 for the HLG curve and its
//     OOTF.
//   * SMPTE ST 2084 for the PQ curve.
//   * ITU-R BT.2390-10 annex 5 for the EETF that tone maps in the PQ domain.
//   * The linear-light rotation between primaries is derived here from their CIE
//     chromaticities, in double precision, and nothing is copied from the code
//     under test.
// The choices that are this project's and not a standard's are the ones the
// kernel documents: 203 nits is white, the tone map is applied to the brightest
// channel, an out-of-gamut colour is desaturated towards its own luminance, and a
// stream that states no peak is taken to be 1000 nits.
//
// Header only and free of Apple frameworks, so a plain C++ test can include it.

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace wallpaper::video::testing_media::hdr
{

enum class Transfer { Sdr, Pq, Hlg };
enum class Primaries { Bt709, Bt2020, P3D65 };

struct Input {
    /// 10-bit code values, as the decoder stores them before the shift into the
    /// top of a 16-bit word.
    int       y { 64 };
    int       cb { 512 };
    int       cr { 512 };
    bool      full_range { false };
    bool      bt2020_matrix { true };
    Transfer  transfer { Transfer::Pq };
    Primaries primaries { Primaries::Bt2020 };
    /// Nits; zero is "not stated".
    double    peak_nits { 0.0 };
};

using Rgb = std::array<double, 3>;
using Matrix = std::array<std::array<double, 3>, 3>;

inline constexpr double kReferenceWhite = 203.0;
inline constexpr double kDefaultPeak    = 1000.0;

// ---- ST 2084 ----------------------------------------------------------------

inline double PqEncode(double nits)
{
    constexpr double m1 = 2610.0 / 16384.0, m2 = 2523.0 / 4096.0 * 128.0;
    constexpr double c1 = 3424.0 / 4096.0, c2 = 2413.0 / 4096.0 * 32.0, c3 = 2392.0 / 4096.0 * 32.0;
    const double y = std::pow(std::clamp(nits / 10000.0, 0.0, 1.0), m1);
    return std::pow((c1 + c2 * y) / (1.0 + c3 * y), m2);
}

inline double PqDecode(double signal)
{
    constexpr double m1 = 2610.0 / 16384.0, m2 = 2523.0 / 4096.0 * 128.0;
    constexpr double c1 = 3424.0 / 4096.0, c2 = 2413.0 / 4096.0 * 32.0, c3 = 2392.0 / 4096.0 * 32.0;
    const double p = std::pow(std::max(signal, 0.0), 1.0 / m2);
    return 10000.0 * std::pow(std::max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
}

// ---- BT.2100 HLG ------------------------------------------------------------

inline Rgb HlgToNits(const Rgb& signal)
{
    constexpr double a = 0.17883277, b = 0.28466892, c = 0.55991073;
    Rgb scene {};
    for (size_t i = 0; i < 3; ++i) {
        const double e = std::clamp(signal[i], 0.0, 1.0);
        scene[i] = e <= 0.5 ? e * e / 3.0 : (std::exp((e - c) / a) + b) / 12.0;
    }
    const double luma = 0.2627 * scene[0] + 0.6780 * scene[1] + 0.0593 * scene[2];
    const double gain = 1000.0 * std::pow(luma, 0.2);  // system gamma 1.2 at 1000 nits
    return { gain * scene[0], gain * scene[1], gain * scene[2] };
}

// ---- BT.2390 EETF -------------------------------------------------------------

/// Maps `nits` of a source whose brightest light is `peak` onto a display whose
/// brightest light is `target`, in the PQ domain, with the standard's hermite
/// roll-off above the knee. The minimum luminance of both is zero.
inline double Eetf(double nits, double peak, double target)
{
    if (peak <= target) return nits;
    const double lw  = PqEncode(peak);
    const double e1  = std::clamp(PqEncode(nits) / lw, 0.0, 1.0);
    const double max_lum = PqEncode(target) / lw;
    const double ks  = 1.5 * max_lum - 0.5;
    double       e2  = e1;
    if (e1 >= ks) {
        const double t = (e1 - ks) / (1.0 - ks);
        e2 = (2 * t * t * t - 3 * t * t + 1) * ks + (t * t * t - 2 * t * t + t) * (1 - ks) +
             (-2 * t * t * t + 3 * t * t) * max_lum;
    }
    return PqDecode(e2 * lw);
}

// ---- Primaries, from chromaticities --------------------------------------------

struct Xy { double x, y; };
struct PrimarySet { Xy r, g, b, w; };

inline PrimarySet PrimariesOf(Primaries p)
{
    switch (p) {
    case Primaries::Bt2020: return { { 0.708, 0.292 }, { 0.170, 0.797 }, { 0.131, 0.046 }, { 0.3127, 0.3290 } };
    case Primaries::P3D65:  return { { 0.680, 0.320 }, { 0.265, 0.690 }, { 0.150, 0.060 }, { 0.3127, 0.3290 } };
    case Primaries::Bt709:  break;
    }
    return { { 0.640, 0.330 }, { 0.300, 0.600 }, { 0.150, 0.060 }, { 0.3127, 0.3290 } };
}

inline Matrix Invert(const Matrix& m)
{
    // Adjugate over determinant, written out by cofactors.
    const double det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
                       m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
                       m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    Matrix r {};
    r[0][0] =  (m[1][1] * m[2][2] - m[1][2] * m[2][1]) / det;
    r[0][1] = -(m[0][1] * m[2][2] - m[0][2] * m[2][1]) / det;
    r[0][2] =  (m[0][1] * m[1][2] - m[0][2] * m[1][1]) / det;
    r[1][0] = -(m[1][0] * m[2][2] - m[1][2] * m[2][0]) / det;
    r[1][1] =  (m[0][0] * m[2][2] - m[0][2] * m[2][0]) / det;
    r[1][2] = -(m[0][0] * m[1][2] - m[0][2] * m[1][0]) / det;
    r[2][0] =  (m[1][0] * m[2][1] - m[1][1] * m[2][0]) / det;
    r[2][1] = -(m[0][0] * m[2][1] - m[0][1] * m[2][0]) / det;
    r[2][2] =  (m[0][0] * m[1][1] - m[0][1] * m[1][0]) / det;
    return r;
}

inline Matrix Product(const Matrix& a, const Matrix& b)
{
    Matrix r {};
    for (size_t i = 0; i < 3; ++i)
        for (size_t j = 0; j < 3; ++j)
            for (size_t k = 0; k < 3; ++k) r[i][j] += a[i][k] * b[k][j];
    return r;
}

inline Matrix RgbToXyz(Primaries p)
{
    const PrimarySet s = PrimariesOf(p);
    const auto       col = [](const Xy& xy) { return Rgb { xy.x / xy.y, 1.0, (1.0 - xy.x - xy.y) / xy.y }; };
    const Rgb        r = col(s.r), g = col(s.g), b = col(s.b), w = col(s.w);
    const Matrix     unscaled {{ { r[0], g[0], b[0] }, { r[1], g[1], b[1] }, { r[2], g[2], b[2] } }};
    const Matrix     inverse = Invert(unscaled);
    Rgb              scale {};
    for (size_t i = 0; i < 3; ++i) scale[i] = inverse[i][0] * w[0] + inverse[i][1] * w[1] + inverse[i][2] * w[2];
    Matrix out {};
    for (size_t i = 0; i < 3; ++i)
        for (size_t j = 0; j < 3; ++j) out[i][j] = unscaled[i][j] * scale[j];
    return out;
}

/// Linear light of `from` primaries as linear light of BT.709's.
inline Rgb To709(const Rgb& rgb, Primaries from)
{
    if (from == Primaries::Bt709) return rgb;
    const Matrix m = Product(Invert(RgbToXyz(Primaries::Bt709)), RgbToXyz(from));
    Rgb out {};
    for (size_t i = 0; i < 3; ++i) out[i] = m[i][0] * rgb[0] + m[i][1] * rgb[1] + m[i][2] * rgb[2];
    return out;
}

inline Rgb SoftClip(Rgb rgb)
{
    const double luma = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
    const double lowest = std::min({ rgb[0], rgb[1], rgb[2] });
    if (lowest < 0.0) {
        if (luma > 0.0) {
            const double s = luma / (luma - lowest);
            for (double& c : rgb) c = luma + (c - luma) * s;
        } else {
            rgb = { 0.0, 0.0, 0.0 };
        }
    }
    const double highest = std::max({ rgb[0], rgb[1], rgb[2] });
    if (highest > 1.0) for (double& c : rgb) c /= highest;
    for (double& c : rgb) c = std::max(c, 0.0);
    return rgb;
}

inline double SrgbEncode(double light)
{
    return light <= 0.0031308 ? 12.92 * light : 1.055 * std::pow(light, 1.0 / 2.4) - 0.055;
}

// ---- The whole conversion -----------------------------------------------------

/// The non-linear R'G'B' the YCbCr codes stand for, before any transfer function.
inline Rgb EncodedRgb(const Input& in)
{
    const double kr = in.bt2020_matrix ? 0.2627 : 0.2126;
    const double kb = in.bt2020_matrix ? 0.0593 : 0.0722;
    const double kg = 1.0 - kr - kb;
    double y = 0.0, cb = 0.0, cr = 0.0;
    if (in.full_range) {
        y  = in.y / 1023.0;
        cb = (in.cb - 512) / 1023.0;
        cr = (in.cr - 512) / 1023.0;
    } else {
        y  = (in.y - 64) / 876.0;
        cb = (in.cb - 512) / 896.0;
        cr = (in.cr - 512) / 896.0;
    }
    y = std::clamp(y, 0.0, 1.0);
    const double r = y + 2.0 * (1.0 - kr) * cr;
    const double b = y + 2.0 * (1.0 - kb) * cb;
    const double g = (y - kr * r - kb * b) / kg;
    return { std::clamp(r, 0.0, 1.0), std::clamp(g, 0.0, 1.0), std::clamp(b, 0.0, 1.0) };
}

/// What the picture on screen should be, as BGRA's encoded values in [0, 1].
inline Rgb ReferenceRgb(const Input& in)
{
    Rgb encoded = EncodedRgb(in);
    if (in.transfer == Transfer::Sdr) {
        if (in.primaries == Primaries::Bt709) return encoded;
        // Display-referred, in wider primaries: rotated in linear light with the
        // 2.4 power law standing for the display.
        Rgb light {};
        for (size_t i = 0; i < 3; ++i) light[i] = std::pow(encoded[i], 2.4);
        Rgb rotated = SoftClip(To709(light, in.primaries));
        for (double& c : rotated) c = std::pow(c, 1.0 / 2.4);
        return rotated;
    }
    Rgb nits {};
    if (in.transfer == Transfer::Pq) {
        for (size_t i = 0; i < 3; ++i) nits[i] = PqDecode(encoded[i]);
    } else {
        nits = HlgToNits(encoded);
    }
    const double peak = std::min(in.peak_nits > 0.0 ? in.peak_nits : kDefaultPeak, 10000.0);
    const double brightest = std::max({ nits[0], nits[1], nits[2] });
    if (brightest > 0.0) {
        const double scale = Eetf(brightest, peak, kReferenceWhite) / brightest;
        for (double& c : nits) c *= scale;
    }
    Rgb light {};
    for (size_t i = 0; i < 3; ++i) light[i] = nits[i] / kReferenceWhite;
    Rgb clipped = SoftClip(To709(light, in.primaries));
    for (double& c : clipped) c = SrgbEncode(c);
    return clipped;
}

/// The 10-bit luma code that a PQ picture carries `nits` at, for a grey pixel.
inline int PqLumaCode(double nits) { return static_cast<int>(std::lround(64.0 + 876.0 * PqEncode(nits))); }

/// The 10-bit luma code an HLG picture carries a grey signal `level` at.
inline int HlgLumaCode(double level) { return static_cast<int>(std::lround(64.0 + 876.0 * level)); }

inline std::array<int, 3> ToBgra8(const Rgb& rgb)
{
    std::array<int, 3> out {};
    for (size_t i = 0; i < 3; ++i) out[i] = static_cast<int>(std::lround(std::clamp(rgb[i], 0.0, 1.0) * 255.0));
    return out;
}

} // namespace wallpaper::video::testing_media::hdr
