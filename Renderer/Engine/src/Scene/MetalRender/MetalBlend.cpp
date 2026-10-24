#include "MetalRender/MetalBlend.hpp"

namespace wallpaper::metal
{

MetalBlendState ToMetalBlendState(BlendMode mode, std::uint32_t sample_count)
{
    // Without multisampling there is no coverage mask to preserve transparency.
    if (mode == BlendMode::AlphaToCoverage && sample_count <= 1) mode = BlendMode::Translucent;
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
        // Source-over coverage is As + Ad * (1 - As), not As squared. Squaring
        // it exposes the background along otherwise opaque overlaps.
        state.source_alpha      = MetalBlendFactor::One;
        state.destination_alpha = MetalBlendFactor::OneMinusSourceAlpha;
        break;
    case BlendMode::Additive:
        state.source_rgb        = MetalBlendFactor::SourceAlpha;
        state.destination_rgb   = MetalBlendFactor::One;
        state.source_alpha      = MetalBlendFactor::SourceAlpha;
        state.destination_alpha = MetalBlendFactor::One;
        break;
    }
    return state;
}

} // namespace wallpaper::metal
