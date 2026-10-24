#pragma once

namespace wallpaper::video
{
// Geometry and color conversion must agree before the renderer samples an
// imported video as an ordinary texture.
inline constexpr const char* kVideoConversionMetalSource = R"(
#include <metal_stdlib>
using namespace metal;
struct YuvColorParams {
    float y_offset; float y_scale; float chroma_offset; float chroma_scale;
    float r_cr; float g_cb; float g_cr; float b_cb;
};
struct VideoTransform {
    float4 matrix;
    float2 offset;
};
float2 video_uv(float2 uv, constant VideoTransform& transform) {
    return float2(dot(uv, transform.matrix.xy), dot(uv, transform.matrix.zw)) + transform.offset;
}
float video_coverage(float2 uv, constant VideoTransform& transform) {
    const bool non_orthogonal = abs(transform.matrix.x * transform.matrix.y) > 1e-6f ||
                                abs(transform.matrix.z * transform.matrix.w) > 1e-6f;
    return non_orthogonal && (any(uv < 0.0f) || any(uv > 1.0f)) ? 0.0f : 1.0f;
}
kernel void nv12_to_bgra(texture2d<float, access::sample> y_texture [[texture(0)]],
                         texture2d<float, access::sample> uv_texture [[texture(1)]],
                         texture2d<half, access::write> output_texture [[texture(2)]],
                         constant YuvColorParams& params [[buffer(0)]],
                         constant VideoTransform& transform [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output_texture.get_width() || gid.y >= output_texture.get_height()) return;
    constexpr sampler sample_state(coord::normalized, address::clamp_to_edge, filter::linear);
    const float2 uv = video_uv((float2(gid) + 0.5f) /
        float2(output_texture.get_width(), output_texture.get_height()), transform);
    const float y = y_texture.sample(sample_state, uv).r;
    const float2 cbcr = (uv_texture.sample(sample_state, uv).rg - params.chroma_offset) * params.chroma_scale;
    const float luma = saturate((y - params.y_offset) * params.y_scale);
    const float3 rgb = saturate(float3(luma + params.r_cr * cbcr.y,
        luma + params.g_cb * cbcr.x + params.g_cr * cbcr.y, luma + params.b_cb * cbcr.x));
    const float coverage = video_coverage(uv, transform);
    output_texture.write(half4(half3(rgb * coverage), half(coverage)), gid);
}
kernel void bgra_transform(texture2d<float, access::sample> source [[texture(0)]],
                            texture2d<half, access::write> output_texture [[texture(2)]],
                            constant VideoTransform& transform [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output_texture.get_width() || gid.y >= output_texture.get_height()) return;
    constexpr sampler sample_state(coord::normalized, address::clamp_to_edge, filter::linear);
    const float2 uv = video_uv((float2(gid) + 0.5f) /
        float2(output_texture.get_width(), output_texture.get_height()), transform);
    output_texture.write(half4(source.sample(sample_state, uv) * video_coverage(uv, transform)), gid);
}
)";

// The 10-bit kernel and what it needs, as a second piece of Metal source that
// is compiled together with the one above, and only by a scene whose video is
// 10-bit. An 8-bit scene, which compiles
// `kVideoConversionMetalSource` alone, neither pays for it nor sees it.
inline constexpr const char* kVideoTenBitConversionMetalSource = R"(
// ---- 10-bit biplanar (P010 / 'x420') -------------------------------------
// The decoder's 10-bit samples sit in the top ten bits of each 16-bit word, so
// a 16-bit unorm sample is code * 64 / 65535 and this brings it back to code /
// 1023, the scale YuvColorParams was made for.
constant float kTenBitCodeScale = 65535.0f / 65472.0f;
// BT.2100 hybrid log-gamma constants and the luma weights of BT.2020.
constant float kHlgA = 0.17883277f;
constant float kHlgB = 0.28466892f;
constant float kHlgC = 0.55991073f;
constant float3 kBt2020Luma = float3(0.2627f, 0.6780f, 0.0593f);
constant float3 kBt709Luma = float3(0.2126f, 0.7152f, 0.0722f);
// The system gamma of the HLG OOTF for a display whose peak is 1000 nits, the
// nominal one of BT.2100.
constant float kHlgSystemGamma = 1.2f;
constant float kHlgNominalPeak = 1000.0f;
// SMPTE ST 2084 constants.
constant float kPqM1 = 2610.0f / 16384.0f;
constant float kPqM2 = 2523.0f / 4096.0f * 128.0f;
constant float kPqC1 = 3424.0f / 4096.0f;
constant float kPqC2 = 2413.0f / 4096.0f * 32.0f;
constant float kPqC3 = 2392.0f / 4096.0f * 32.0f;
// Mirrors HdrConversionParams in VideoColorConversion.hpp (64 bytes).
struct HdrParams {
    uint transfer;              // 0 display-referred, 1 PQ, 2 HLG
    float source_peak_nits;
    float reference_white_nits;
    uint convert_gamut;
    float4 gamut0;
    float4 gamut1;
    float4 gamut2;
};
float3 pq_to_nits(float3 encoded) {
    const float3 p = pow(max(encoded, 0.0f), 1.0f / kPqM2);
    return 10000.0f * pow(max(p - kPqC1, 0.0f) / (kPqC2 - kPqC3 * p), 1.0f / kPqM1);
}
float nits_to_pq(float nits) {
    const float p = pow(clamp(nits / 10000.0f, 0.0f, 1.0f), kPqM1);
    return pow((kPqC1 + kPqC2 * p) / (1.0f + kPqC3 * p), kPqM2);
}
// HLG signal to display light in nits: the inverse OETF to scene light, then
// the OOTF of a 1000 nit display. A signal of 0.75 comes out at about 203 nits.
float3 hlg_to_nits(float3 encoded) {
    const float3 e = clamp(encoded, 0.0f, 1.0f);
    const float3 scene = select((exp((e - kHlgC) / kHlgA) + kHlgB) / 12.0f, e * e / 3.0f, e <= 0.5f);
    const float luma = dot(scene, kBt2020Luma);
    return kHlgNominalPeak * pow(max(luma, 0.0f), kHlgSystemGamma - 1.0f) * scene;
}
// The BT.2390 EETF for one luminance: a hermite roll-off, in the PQ domain,
// that leaves everything below its knee alone and brings `peak` down to
// `target`. A source that is not brighter than the target is left as it is.
float tone_map_nits(float nits, float peak, float target) {
    if (peak <= target) return nits;
    const float source_max = nits_to_pq(peak);
    const float e1 = clamp(nits_to_pq(nits) / source_max, 0.0f, 1.0f);
    const float max_luminance = nits_to_pq(target) / source_max;
    const float knee = 1.5f * max_luminance - 0.5f;
    float e2 = e1;
    if (e1 >= knee) {
        const float t = (e1 - knee) / (1.0f - knee);
        const float t2 = t * t;
        const float t3 = t2 * t;
        e2 = (2.0f * t3 - 3.0f * t2 + 1.0f) * knee + (t3 - 2.0f * t2 + t) * (1.0f - knee) +
             (-2.0f * t3 + 3.0f * t2) * max_luminance;
    }
    return pq_to_nits(float3(e2 * source_max)).x;
}
// What a colour that fell outside BT.709 becomes: desaturated towards its own
// luminance just far enough that no channel is negative, then scaled down if a
// channel is over one. Hue and luminance are kept instead of each channel being
// cut off on its own.
float3 soft_clip_gamut(float3 rgb) {
    const float luma = dot(rgb, kBt709Luma);
    const float lowest = min(rgb.r, min(rgb.g, rgb.b));
    if (lowest < 0.0f) {
        rgb = luma > 0.0f ? luma + (rgb - luma) * (luma / (luma - lowest)) : float3(0.0f);
    }
    const float highest = max(rgb.r, max(rgb.g, rgb.b));
    if (highest > 1.0f) rgb /= highest;
    return max(rgb, 0.0f);
}
float3 srgb_encode(float3 light) {
    return select(1.055f * pow(light, 1.0f / 2.4f) - 0.055f, light * 12.92f, light <= 0.0031308f);
}
kernel void p010_to_bgra(texture2d<float, access::sample> y_texture [[texture(0)]],
                         texture2d<float, access::sample> uv_texture [[texture(1)]],
                         texture2d<half, access::write> output_texture [[texture(2)]],
                         constant YuvColorParams& params [[buffer(0)]],
                         constant VideoTransform& transform [[buffer(1)]],
                         constant HdrParams& hdr [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output_texture.get_width() || gid.y >= output_texture.get_height()) return;
    constexpr sampler sample_state(coord::normalized, address::clamp_to_edge, filter::linear);
    const float2 uv = video_uv((float2(gid) + 0.5f) /
        float2(output_texture.get_width(), output_texture.get_height()), transform);
    const float y = y_texture.sample(sample_state, uv).r * kTenBitCodeScale;
    const float2 cbcr = (uv_texture.sample(sample_state, uv).rg * kTenBitCodeScale - params.chroma_offset) *
        params.chroma_scale;
    const float luma = saturate((y - params.y_offset) * params.y_scale);
    // The picture's own non-linear R'G'B'.
    float3 rgb = saturate(float3(luma + params.r_cr * cbcr.y,
        luma + params.g_cb * cbcr.x + params.g_cr * cbcr.y, luma + params.b_cb * cbcr.x));
    if (hdr.transfer != 0u) {
        // Light in nits, then in units of the SDR white (1.0 = reference white).
        float3 nits = hdr.transfer == 1u ? pq_to_nits(rgb) : hlg_to_nits(rgb);
        // Tone mapped on the brightest channel, so that the ratio between the
        // channels, and with it hue and saturation, survives the compression.
        const float brightest = max(nits.r, max(nits.g, nits.b));
        if (brightest > 0.0f) {
            nits *= tone_map_nits(brightest, hdr.source_peak_nits, hdr.reference_white_nits) / brightest;
        }
        float3 light = nits / hdr.reference_white_nits;
        if (hdr.convert_gamut != 0u) {
            light = float3(dot(hdr.gamut0.xyz, light), dot(hdr.gamut1.xyz, light), dot(hdr.gamut2.xyz, light));
        }
        rgb = srgb_encode(soft_clip_gamut(light));
    } else if (hdr.convert_gamut != 0u) {
        // Display-referred 10-bit in wider primaries: rotated in linear light,
        // with the 2.4 power law of BT.1886 standing for the display, so the
        // mid-tones come out where they would have without the rotation.
        const float3 light = pow(rgb, 2.4f);
        const float3 rotated = float3(dot(hdr.gamut0.xyz, light), dot(hdr.gamut1.xyz, light), dot(hdr.gamut2.xyz, light));
        rgb = pow(soft_clip_gamut(rotated), 1.0f / 2.4f);
    }
    // Otherwise 10-bit BT.709 video is a picture the display already expects:
    // nothing is tone mapped, and the codes are written as they decode.
    const float coverage = video_coverage(uv, transform);
    output_texture.write(half4(half3(rgb * coverage), half(coverage)), gid);
}
)";
} // namespace wallpaper::video
