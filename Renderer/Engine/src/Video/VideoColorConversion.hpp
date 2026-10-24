#pragma once

#include <cstdint>

namespace wallpaper::video
{

enum class YuvRange {
    /// Studio swing: 8-bit luma occupies 16..235 and chroma 16..240, so the two
    /// components have different excursions and cannot share one scale.
    Limited,
    /// Full swing: every code value is used.
    Full,
};

enum class YuvMatrix {
    Bt601,
    Bt709,
    /// Non-constant luminance only. Constant-luminance BT.2020 is a different
    /// transform and is not covered by these coefficients.
    Bt2020NonConstantLuminance,
};

/// The transfer function a frame's code values are encoded with. Everything
/// that is not one of the two HDR curves is display-referred ("SDR"): BT.709,
/// BT.601, sRGB and an unstated transfer all pass through as they are.
enum class YuvTransfer : uint8_t {
    Sdr,
    /// SMPTE ST 2084 (perceptual quantizer), absolute luminance up to 10000 nits.
    Pq,
    /// ARIB STD-B67 / BT.2100 hybrid log-gamma, scene-referred.
    Hlg,
};

/// The red, green and blue primaries the colour values refer to.
enum class ColorPrimaries : uint8_t {
    Bt709,
    Bt2020,
    P3D65,
};

/// What a decoded frame says about its own color encoding.
struct YuvColorDescription {
    YuvMatrix matrix { YuvMatrix::Bt709 };
    YuvRange  range { YuvRange::Limited };
    uint32_t  bit_depth { 8 };
    /// Set when the source carried no usable matrix and one had to be inferred,
    /// so the choice can be reported instead of silently assumed.
    bool      matrix_inferred { false };
    YuvTransfer    transfer { YuvTransfer::Sdr };
    ColorPrimaries primaries { ColorPrimaries::Bt709 };
    /// The brightest light, in nits, the stream says it carries: its content
    /// light level when it states one, else its mastering display's peak. Zero
    /// when it states neither. Only the HDR curves look at it.
    float     peak_nits { 0.0f };
};

/// Conversion constants in normalized [0,1] sample space, shared verbatim by
/// the CPU path and the Metal kernel so the two cannot drift apart.
///
///   luma   = (sample - y_offset) * y_scale
///   chroma = (sample - chroma_offset) * chroma_scale
struct YuvColorParams {
    float y_offset { 0.0f };
    float y_scale { 1.0f };
    float chroma_offset { 0.0f };
    float chroma_scale { 1.0f };
    float r_cr { 0.0f };
    float g_cb { 0.0f };
    float g_cr { 0.0f };
    float b_cb { 0.0f };
};

/// The luminance one HDR frame is judged against. Linear light is scaled so that
/// this reads 1.0, the white of a standard-dynamic-range picture (BT.2408's
/// reference white); everything brighter is what tone mapping has to fit.
inline constexpr float kReferenceWhiteNits = 203.0f;
/// The peak assumed for an HDR stream that states none, which is what most
/// consumer HDR is graded to.
inline constexpr float kDefaultHdrPeakNits = 1000.0f;
/// The brightest light either HDR curve can express.
inline constexpr float kMaximumHdrPeakNits = 10000.0f;

/// What the 10-bit conversion kernel needs beyond `YuvColorParams`. The layout
/// is mirrored by `HdrParams` in `VideoConversionMetal.hpp` and checked by the
/// size assertion below: change both together.
struct HdrConversionParams {
    /// `YuvTransfer` as an integer: 0 SDR, 1 PQ, 2 HLG.
    uint32_t transfer { 0 };
    /// Where the tone map starts compressing from, in nits.
    float    source_peak_nits { kDefaultHdrPeakNits };
    float    reference_white_nits { kReferenceWhiteNits };
    /// Non-zero when the frame's primaries differ from BT.709's and its linear
    /// light has to be rotated into them.
    uint32_t convert_gamut { 0 };
    /// Rows of the linear-light RGB conversion into BT.709 primaries; the fourth
    /// column is padding.
    float    gamut[3][4] {
        { 1.0f, 0.0f, 0.0f, 0.0f },
        { 0.0f, 1.0f, 0.0f, 0.0f },
        { 0.0f, 0.0f, 1.0f, 0.0f },
    };
};
static_assert(sizeof(HdrConversionParams) == 64, "HdrParams in the Metal source is 64 bytes");

/// The kernel constants for a frame: its transfer, the nits its tone map starts
/// from (the stated peak, else 1000, never above what the curves can express),
/// and the rotation of its primaries into BT.709's, derived from the primaries'
/// chromaticities rather than typed in.
[[nodiscard]] HdrConversionParams MakeHdrConversionParams(const YuvColorDescription& description);

/// Chooses a matrix for a frame whose metadata is unspecified. Standard
/// definition predates BT.709, so height decides; the result is always marked
/// as inferred.
[[nodiscard]] YuvMatrix InferYuvMatrix(uint32_t width, uint32_t height);

[[nodiscard]] YuvColorParams MakeYuvColorParams(const YuvColorDescription& description);

struct Rgb8 {
    uint8_t red { 0 };
    uint8_t green { 0 };
    uint8_t blue { 0 };
};

/// Converts one 8-bit YCbCr sample triple. The reference for the CPU path and
/// for the GPU comparison tests.
[[nodiscard]] Rgb8 ConvertYuvCodeToRgb8(const YuvColorParams& params,
                                        uint8_t luma_code,
                                        uint8_t cb_code,
                                        uint8_t cr_code);

[[nodiscard]] const char* YuvMatrixName(YuvMatrix matrix);
[[nodiscard]] const char* YuvRangeName(YuvRange range);

} // namespace wallpaper::video
