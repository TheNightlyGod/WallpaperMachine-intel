// Known-pixel regressions for YUV to RGB conversion. Limited-range chroma has
// its own 224 code-value excursion: treating it as `sample - 0.5` with the
// standard coefficients desaturates and shifts every studio-swing frame.
#include "Video/VideoColorConversion.hpp"
#include "Video/VideoDisplayTransform.hpp"
#include "video_orientation_cases.hpp"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace wallpaper::video
{
namespace
{

TEST(VideoDisplayTransform, EveryOrthogonalDisplayMatrixMapsTheExpectedCorners) {
    constexpr std::array<std::array<float, 2>, 4> corners {{{0, 0}, {1, 0}, {0, 1}, {1, 1}}};
    for (const auto& orientation : testing_media::kOrientations) {
        SCOPED_TRACE(orientation.name);
        const auto transform = ResolveVideoDisplayTransform(orientation.matrix(), 16, 8);
        ASSERT_TRUE(transform.has_value());
        EXPECT_EQ(transform->width, orientation.swaps_axes ? 8u : 16u);
        EXPECT_EQ(transform->height, orientation.swaps_axes ? 16u : 8u);
        for (size_t index = 0; index < corners.size(); ++index) {
            const auto [u, v] = corners[index];
            const auto& expected = corners[orientation.source_quadrants[index]];
            EXPECT_FLOAT_EQ(transform->matrix[0] * u + transform->matrix[1] * v + transform->offset[0], expected[0]);
            EXPECT_FLOAT_EQ(transform->matrix[2] * u + transform->matrix[3] * v + transform->offset[1], expected[1]);
        }
    }
}

TEST(VideoDisplayTransform, AffineScaleAndShearKeepTheImageCenterAndBoundingSize) {
    const auto transform = ResolveVideoDisplayTransform({65536, 0, 0, 32768, 65536, 0, 0, 0, 1 << 30}, 16, 8);
    ASSERT_TRUE(transform.has_value());
    EXPECT_EQ(transform->width, 20u); EXPECT_EQ(transform->height, 8u);
    EXPECT_FLOAT_EQ((transform->matrix[0] + transform->matrix[1]) * 0.5f + transform->offset[0], 0.5f);
    EXPECT_FLOAT_EQ((transform->matrix[2] + transform->matrix[3]) * 0.5f + transform->offset[1], 0.5f);
    const auto scaled = ResolveVideoDisplayTransform({131072, 0, 0, 0, 196608, 0, 0, 0, 1 << 30}, 16, 8);
    ASSERT_TRUE(scaled.has_value());
    EXPECT_EQ(scaled->width, 32u); EXPECT_EQ(scaled->height, 24u);
    EXPECT_TRUE(scaled->identity());
}

YuvColorParams Params(YuvMatrix matrix, YuvRange range, uint32_t bit_depth = 8)
{
    return MakeYuvColorParams({ .matrix = matrix, .range = range, .bit_depth = bit_depth });
}

/// The conversion this project used before the shared parameters existed:
/// limited-range luma handling with chroma read as `sample/255 - 0.5`.
Rgb8 LegacyConvert(YuvMatrix matrix, YuvRange range, uint8_t y, uint8_t cb, uint8_t cr)
{
    const YuvColorParams reference = Params(matrix, range);
    const float luma = std::clamp(
        (static_cast<float>(y) / 255.0f - reference.y_offset) * reference.y_scale, 0.0f, 1.0f);
    const float chroma_b = static_cast<float>(cb) / 255.0f - 0.5f;
    const float chroma_r = static_cast<float>(cr) / 255.0f - 0.5f;
    const auto quantize = [](float value) {
        return static_cast<uint8_t>(std::lround(std::clamp(value, 0.0f, 1.0f) * 255.0f));
    };
    return Rgb8 {
        .red = quantize(luma + reference.r_cr * chroma_r),
        .green = quantize(luma + reference.g_cb * chroma_b + reference.g_cr * chroma_r),
        .blue = quantize(luma + reference.b_cb * chroma_b),
    };
}

void ExpectRgb(Rgb8 actual, int red, int green, int blue, int tolerance = 1)
{
    EXPECT_NEAR(static_cast<int>(actual.red), red, tolerance);
    EXPECT_NEAR(static_cast<int>(actual.green), green, tolerance);
    EXPECT_NEAR(static_cast<int>(actual.blue), blue, tolerance);
}

TEST(VideoColorConversion, LimitedRangeChromaUsesItsOwnExcursion)
{
    // BT.709 limited range, Y=126 Cb=128 Cr=160. Reference conversion:
    // Y'=(126-16)/219, Cr=(160-128)/224, giving (185, 111, 128).
    const auto converted = ConvertYuvCodeToRgb8(Params(YuvMatrix::Bt709, YuvRange::Limited),
                                                126, 128, 160);
    ExpectRgb(converted, 185, 111, 128);

    // Reading chroma as `sample - 0.5` instead lands six code values away on
    // red: that difference is the defect this test defends against.
    const auto legacy = LegacyConvert(YuvMatrix::Bt709, YuvRange::Limited, 126, 128, 160);
    ExpectRgb(legacy, 179, 113, 128);
    EXPECT_NE(converted.red, legacy.red);
}

TEST(VideoColorConversion, NeutralChromaIsUnaffectedByTheChromaScale)
{
    // At the midpoint the chroma terms vanish, so only luma handling shows. A
    // regression here would mean the luma range was broken instead.
    for (const auto matrix : { YuvMatrix::Bt601, YuvMatrix::Bt709,
                               YuvMatrix::Bt2020NonConstantLuminance }) {
        const auto limited = ConvertYuvCodeToRgb8(Params(matrix, YuvRange::Limited), 126, 128, 128);
        ExpectRgb(limited, 128, 128, 128);
        const auto full = ConvertYuvCodeToRgb8(Params(matrix, YuvRange::Full), 128, 128, 128);
        ExpectRgb(full, 128, 128, 128);
    }
}

TEST(VideoColorConversion, StudioSwingBlackAndWhiteMapToTheFullOutputRange)
{
    const auto params = Params(YuvMatrix::Bt709, YuvRange::Limited);
    ExpectRgb(ConvertYuvCodeToRgb8(params, 16, 128, 128), 0, 0, 0);
    ExpectRgb(ConvertYuvCodeToRgb8(params, 235, 128, 128), 255, 255, 255);
    // Footroom and headroom clamp rather than wrap into the opposite end.
    ExpectRgb(ConvertYuvCodeToRgb8(params, 0, 128, 128), 0, 0, 0);
    ExpectRgb(ConvertYuvCodeToRgb8(params, 255, 128, 128), 255, 255, 255);
}

TEST(VideoColorConversion, FullSwingBlackAndWhiteUseEveryCodeValue)
{
    const auto params = Params(YuvMatrix::Bt709, YuvRange::Full);
    ExpectRgb(ConvertYuvCodeToRgb8(params, 0, 128, 128), 0, 0, 0);
    ExpectRgb(ConvertYuvCodeToRgb8(params, 255, 128, 128), 255, 255, 255);
    // 16 is ordinary shadow detail in full swing, not black.
    EXPECT_GT(static_cast<int>(ConvertYuvCodeToRgb8(params, 16, 128, 128).red), 10);
}

TEST(VideoColorConversion, SeventyFivePercentColorBarsRoundTripToTheirRgbPrimaries)
{
    // Studio-swing BT.709 code values obtained by the forward matrix from the
    // 75% bar primaries, so the expectation is the original RGB rather than a
    // number copied out of the implementation.
    struct Bar {
        uint8_t y, cb, cr;
        int     red, green, blue;
    };
    const Bar bars[] = {
        { 180, 128, 128, 191, 191, 191 },  // 75% white
        { 168,  44, 136, 191, 191,   0 },  // yellow
        { 145, 147,  44,   0, 191, 191 },  // cyan
        { 133,  63,  52,   0, 191,   0 },  // green
        {  63, 193, 204, 191,   0, 191 },  // magenta
        {  51, 109, 212, 191,   0,   0 },  // red
        {  28, 212, 120,   0,   0, 191 },  // blue
    };
    const auto params = Params(YuvMatrix::Bt709, YuvRange::Limited);
    for (const auto& bar : bars) {
        SCOPED_TRACE(testing::Message() << "Y=" << int(bar.y) << " Cb=" << int(bar.cb)
                                        << " Cr=" << int(bar.cr));
        // Two code values of slack absorb the rounding of the code values only.
        ExpectRgb(ConvertYuvCodeToRgb8(params, bar.y, bar.cb, bar.cr),
                  bar.red, bar.green, bar.blue, 2);
    }

    // The same bars through the old chroma handling collapse towards grey: a
    // fully saturated primary must not come back desaturated.
    const auto legacy_red = LegacyConvert(YuvMatrix::Bt709, YuvRange::Limited, 51, 109, 212);
    EXPECT_LT(static_cast<int>(legacy_red.red), 185)
        << "the legacy chroma scale loses saturation on a 75% red bar";
}

TEST(VideoColorConversion, MatricesStayDistinctForSaturatedChroma)
{
    // A shared simplified matrix for every colorimetry would make these equal.
    const auto bt601 = ConvertYuvCodeToRgb8(Params(YuvMatrix::Bt601, YuvRange::Limited),
                                            120, 90, 200);
    const auto bt709 = ConvertYuvCodeToRgb8(Params(YuvMatrix::Bt709, YuvRange::Limited),
                                            120, 90, 200);
    const auto bt2020 = ConvertYuvCodeToRgb8(
        Params(YuvMatrix::Bt2020NonConstantLuminance, YuvRange::Limited), 120, 90, 200);
    ExpectRgb(bt601, 236, 77, 44);
    ExpectRgb(bt709, 250, 91, 41);
    ExpectRgb(bt2020, 242, 81, 40);
    EXPECT_NE(bt601.green, bt709.green);
    EXPECT_NE(bt709.green, bt2020.green);
}

TEST(VideoColorConversion, UnspecifiedMetadataInfersByResolutionRatherThanAlwaysBt601)
{
    EXPECT_EQ(InferYuvMatrix(720, 480), YuvMatrix::Bt601);
    EXPECT_EQ(InferYuvMatrix(720, 576), YuvMatrix::Bt601);
    EXPECT_EQ(InferYuvMatrix(1280, 720), YuvMatrix::Bt709);
    EXPECT_EQ(InferYuvMatrix(1920, 1080), YuvMatrix::Bt709);
    EXPECT_EQ(InferYuvMatrix(3840, 2160), YuvMatrix::Bt709);
    // An anamorphic standard-definition frame is wider than its storage height
    // suggests, and must not be promoted to BT.709 by height alone.
    EXPECT_EQ(InferYuvMatrix(1920, 480), YuvMatrix::Bt709);
    EXPECT_EQ(InferYuvMatrix(1024, 576), YuvMatrix::Bt601);
}

TEST(VideoColorConversion, HigherBitDepthsScaleFootroomAndMidpoint)
{
    const auto ten_bit = Params(YuvMatrix::Bt709, YuvRange::Limited, 10);
    // 10-bit studio swing puts black at 64 and the chroma midpoint at 512 of
    // 1023, which is the same fraction as 16 and 128 of 255.
    EXPECT_NEAR(ten_bit.y_offset, 64.0f / 1023.0f, 1e-6f);
    EXPECT_NEAR(ten_bit.chroma_offset, 512.0f / 1023.0f, 1e-6f);
    EXPECT_NEAR(ten_bit.y_scale, 1023.0f / (219.0f * 4.0f), 1e-6f);
    EXPECT_NEAR(ten_bit.chroma_scale, 1023.0f / (224.0f * 4.0f), 1e-6f);

    // Normalizing by the maximum code value makes the two depths agree to
    // within one eight-bit code value, not exactly: 512/1023 is slightly below
    // 128/255 because neither range is a power of two.
    const auto eight_bit = Params(YuvMatrix::Bt709, YuvRange::Limited, 8);
    constexpr float one_eight_bit_code = 1.0f / 255.0f;
    EXPECT_NEAR(ten_bit.y_offset, eight_bit.y_offset, one_eight_bit_code);
    EXPECT_NEAR(ten_bit.chroma_offset, eight_bit.chroma_offset, one_eight_bit_code);
}

TEST(VideoColorConversion, FullSwingChromaSpansTheWholeCodeRange)
{
    const auto full = Params(YuvMatrix::Bt709, YuvRange::Full);
    const auto limited = Params(YuvMatrix::Bt709, YuvRange::Limited);
    EXPECT_NEAR(full.chroma_scale, 1.0f, 1e-6f);
    EXPECT_GT(limited.chroma_scale, full.chroma_scale);
    EXPECT_NEAR(limited.chroma_scale, 255.0f / 224.0f, 1e-6f);
}

TEST(VideoColorConversion, GamutRotationIntoBt709IsDerivedFromThePrimaries)
{
    // The published BT.2087 matrix for BT.2020 to BT.709 linear light, which is
    // what chromaticities and a shared D65 white point have to produce.
    YuvColorDescription description {};
    description.primaries = ColorPrimaries::Bt2020;
    description.transfer = YuvTransfer::Pq;
    const auto rec2020 = MakeHdrConversionParams(description);
    EXPECT_EQ(rec2020.convert_gamut, 1u);
    const float bt2087[3][3] = {
        { 1.6605f, -0.5876f, -0.0728f },
        { -0.1246f, 1.1329f, -0.0083f },
        { -0.0182f, -0.1006f, 1.1187f },
    };
    for (int row = 0; row < 3; ++row) {
        for (int column = 0; column < 3; ++column) {
            EXPECT_NEAR(rec2020.gamut[row][column], bt2087[row][column], 2e-4f) << row << "," << column;
        }
        // White stays white: a rotation between primaries that share a white
        // point maps (1, 1, 1) to (1, 1, 1).
        EXPECT_NEAR(rec2020.gamut[row][0] + rec2020.gamut[row][1] + rec2020.gamut[row][2], 1.0f, 1e-4f);
    }

    description.primaries = ColorPrimaries::P3D65;
    const auto p3 = MakeHdrConversionParams(description);
    const float p3_to_709[3][3] = {
        { 1.2249f, -0.2247f, 0.0f },
        { -0.0420f, 1.0419f, 0.0f },
        { -0.0197f, -0.0786f, 1.0979f },
    };
    for (int row = 0; row < 3; ++row) {
        for (int column = 0; column < 3; ++column) {
            EXPECT_NEAR(p3.gamut[row][column], p3_to_709[row][column], 5e-4f) << row << "," << column;
        }
    }

    // BT.709 needs no rotation, and says so instead of multiplying by identity.
    description.primaries = ColorPrimaries::Bt709;
    EXPECT_EQ(MakeHdrConversionParams(description).convert_gamut, 0u);
}

TEST(VideoColorConversion, TheToneMapStartsFromTheStatedPeakElseOneThousandNits)
{
    YuvColorDescription description {};
    description.transfer = YuvTransfer::Pq;
    EXPECT_EQ(MakeHdrConversionParams(description).source_peak_nits, kDefaultHdrPeakNits);
    EXPECT_EQ(MakeHdrConversionParams(description).transfer, 1u);
    description.transfer = YuvTransfer::Hlg;
    EXPECT_EQ(MakeHdrConversionParams(description).transfer, 2u);

    description.peak_nits = 600.0f;
    EXPECT_EQ(MakeHdrConversionParams(description).source_peak_nits, 600.0f);
    // The curves cannot express more than 10000 nits, so a stream that says
    // otherwise is not believed.
    description.peak_nits = 40000.0f;
    EXPECT_EQ(MakeHdrConversionParams(description).source_peak_nits, kMaximumHdrPeakNits);
    EXPECT_EQ(MakeHdrConversionParams(description).reference_white_nits, kReferenceWhiteNits);

    description.transfer = YuvTransfer::Sdr;
    EXPECT_EQ(MakeHdrConversionParams(description).transfer, 0u);
}

} // namespace
} // namespace wallpaper::video
