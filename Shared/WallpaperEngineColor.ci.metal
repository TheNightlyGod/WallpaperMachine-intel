#include <CoreImage/CoreImage.h>

// Wallpaper Engine's colour adjustment (`ccsimple.frag`, combo COL) as a Core Image kernel,
// for the video players. `params` is (brightness², √contrast, √saturation, hue shift) as
// `wallpaper64.exe` `sub_140181F30` packs `g_Params`; rgb2hsv / hsv2rgb are copied verbatim
// from the shipped `shaders/common.h`. Input and output are sRGB-encoded, as the scene draws
// it. Loads from the target's default.metallib without -fcikernel (plan check P0-4).
extern "C" { namespace coreimage {

static float3 weRgb2Hsv(float3 rgb) {
    float4 p = (rgb.g < rgb.b) ? float4(rgb.bg, -1.0, 2.0 / 3.0) : float4(rgb.gb, 0.0, -1.0 / 3.0);
    float4 q = (rgb.r < p.x) ? float4(p.xyw, rgb.r) : float4(rgb.r, p.yzx);
    float c = q.x - min(q.w, q.y);
    float h = abs((q.w - q.y) / (6.0 * c + 1e-10) + q.z);
    float s = c / (q.x + 1e-10);
    return float3(h, s, q.x);
}

static float3 weHsv2Rgb(float3 c) {
    float4 k = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + k.xyz) * 6.0 - k.www);
    return c.z * mix(k.xxx, clamp(p - k.xxx, 0.0, 1.0), c.y);
}

[[stitchable]] float4 wallpaperEngineColor(sample_t s, float4 params) {
    // Core Image samples are premultiplied; ccsimple adjusts straight RGB.
    float3 rgb = s.a > 0.0 ? s.rgb / s.a : float3(0.0);
    rgb = mix(float3(0.5), rgb, params.y);
    float3 hsv = weRgb2Hsv(rgb);
    hsv.z *= params.x;
    hsv.y *= params.z;
    hsv.x += params.w;
    return float4(weHsv2Rgb(hsv) * s.a, s.a);
}

}}
