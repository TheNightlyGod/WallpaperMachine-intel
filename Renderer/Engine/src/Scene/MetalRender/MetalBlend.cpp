// Wallpaper Engine 2.8.0.42 blend states (`sub_140099F60`). Its device keeps four
// more blend flags, set through vtable 0x140485B90: +240 `sub_14009B070` 0x80
// (premultiplied ONE / INV_SRC_ALPHA), +248 `sub_14009B0A0` 0x20 (colour MAX),
// +256 `sub_14009B0D0` 0x40 (colour MIN) and +264 `sub_14009B100` 0x100 (DEST_COLOR
// multiply). Only 0x100 has a caller: `sub_14020D6A0`, which multiplies a puppet's
// nested clipping masks together (BlendMode::Multiply). No code in wallpaper64.exe
// calls the other three setters or writes those bits; the call sites the plan named
// (`sub_1400D2B20`, `sub_1400D2C60`, `sub_1400D3500`, `sub_140121C60`, `sub_14012AC60`,
// `sub_1401E8AA0`) reach other interfaces' +240/+264 (Direct3D, Media Foundation).
// Record: artifacts/we-parity/decompiles/I16-blend-flags.md.
#include "MetalRender/MetalBlend.hpp"

namespace wallpaper::metal
{

MetalBlendState ToMetalBlendState(BlendMode mode, AlphaBlendRule alpha_rule,
                                  std::uint32_t sample_count)
{
    // `alphatocoverage` keeps coverage on and blending off at every sample count: with one
    // sample Metal keeps fragments above half alpha and drops those below it, which is
    // Direct3D's single-sample coverage too (Wallpaper Engine mode 3, `sub_140099F60`;
    // `MetalSceneDraw.MetalSingleSampleAlphaToCoverageThresholdsAtHalf`).
    (void)sample_count;
    MetalBlendState state {};
    state.blending_enabled = true;
    state.rgb_operation    = MetalBlendOperation::Add;
    state.alpha_operation  = MetalBlendOperation::Add;

    switch (mode) {
    case BlendMode::Disable:
        state.blending_enabled = false;
        break;
    case BlendMode::Normal:
        // An opaque replace, not source-over. The authored name is misleading
        // and Wallpaper Engine writes exactly these factors.
        state.source_rgb        = MetalBlendFactor::One;
        state.destination_rgb   = MetalBlendFactor::Zero;
        state.source_alpha      = MetalBlendFactor::One;
        state.destination_alpha = MetalBlendFactor::Zero;
        break;
    case BlendMode::AlphaToCoverage:
        // Coverage decides what is kept; kept samples are written unblended.
        state.blending_enabled  = false;
        state.alpha_to_coverage = true;
        break;
    case BlendMode::Translucent:
        state.source_rgb      = MetalBlendFactor::SourceAlpha;
        state.destination_rgb = MetalBlendFactor::OneMinusSourceAlpha;
        // Wallpaper Engine blends alpha with the colour's factors, As * As +
        // Ad * (1 - As) (sub_140099F60). Only a layer's own picture into its
        // composite keeps source-over coverage, As + Ad * (1 - As).
        state.source_alpha = alpha_rule == AlphaBlendRule::SourceOver ? MetalBlendFactor::One
                                                                      : MetalBlendFactor::SourceAlpha;
        state.destination_alpha = MetalBlendFactor::OneMinusSourceAlpha;
        break;
    case BlendMode::Multiply:
        state.source_rgb        = MetalBlendFactor::DestinationColor;
        state.destination_rgb   = MetalBlendFactor::OneMinusSourceAlpha;
        state.source_alpha      = MetalBlendFactor::One;
        state.destination_alpha = MetalBlendFactor::One;
        break;
    case BlendMode::Additive:
        state.source_rgb        = MetalBlendFactor::SourceAlpha;
        state.destination_rgb   = MetalBlendFactor::One;
        state.source_alpha      = MetalBlendFactor::SourceAlpha;
        state.destination_alpha = MetalBlendFactor::One;
        break;
    }
    // The children of a layer without copybackground: BlendOpAlpha MAX, ONE / ONE
    // (sub_1401ECB20, flag 0x10 of sub_140099F60). An unblended draw writes its
    // alpha as it is, so the rule changes only blended modes.
    if (alpha_rule == AlphaBlendRule::Max && state.blending_enabled &&
        (mode == BlendMode::Translucent || mode == BlendMode::Additive ||
         mode == BlendMode::Multiply)) {
        state.alpha_operation   = MetalBlendOperation::Max;
        state.source_alpha      = MetalBlendFactor::One;
        state.destination_alpha = MetalBlendFactor::One;
    }
    return state;
}

} // namespace wallpaper::metal
