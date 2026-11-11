#pragma once

#import <Metal/Metal.h>

#include "Presentation/BackdropGeometry.hpp"

#include <cstdint>
#include <string>
#include <vector>
#include <unordered_map>

namespace wallpaper::metal
{

/// The soft, darker copy of the picture that "Fit with blurred backdrop" shows in the room the
/// picture leaves.
///
/// Each composed frame the copy is made again on the GPU from the scene's final output: reduced
/// to a small image, blurred, and later stretched over the bands around the picture. Everything
/// here exists only for as long as that mode needs it. The pipelines are built when the mode is
/// chosen, between frames; the images are made on the first frame whose composition has room
/// to fill and let go on the first one that has none.
class MetalBackdrop {
public:
    MetalBackdrop();
    ~MetalBackdrop();
    MetalBackdrop(const MetalBackdrop&)            = delete;
    MetalBackdrop& operator=(const MetalBackdrop&) = delete;

    /// Compiles the shaders and builds the pipelines for compositions into `destination`.
    /// False, with `error()`, if that fails; nothing is then drawn and the bars stay clear.
    bool buildPipelines(id<MTLDevice> device, MTLPixelFormat destination, bool source_linear = false);
    [[nodiscard]] bool pipelinesBuilt() const { return built_; }
    /// Whether a composition into this format can draw the copy.
    [[nodiscard]] bool canDraw(MTLPixelFormat destination) const;

    /// Releases the pipelines and the images.
    void release();
    /// Releases the images only.
    void releaseImages();

    /// Encodes the reductions and the blur of `source` into `command`, making the images first
    /// if there are none for a source of this size. False if that cannot be done.
    bool encodeMaking(id<MTLCommandBuffer> command, id<MTLTexture> source);

    /// Draws the copy into `bands` of the encoder's render pass. `viewport` places the copy as
    /// the picture's would be placed; `mirrored` flips it left to right like the picture.
    void encodeBands(id<MTLRenderCommandEncoder> encoder, const SurroundBands& bands,
                     const MTLViewport& viewport, bool mirrored) const;

    /// Bytes Metal allocated for the images that exist now.
    [[nodiscard]] uint64_t allocatedBytes() const;
    [[nodiscard]] bool hasImages() const { return !chain_.empty(); }
    [[nodiscard]] const std::string& error() const { return error_; }

private:
    bool makeImages(uint32_t source_width, uint32_t source_height);

    id<MTLDevice>              device_ { nil };
    id<MTLLibrary>             library_ { nil };
    id<MTLRenderPipelineState> reduce_8bit_ { nil };
    id<MTLRenderPipelineState> reduce_half_ { nil };
    id<MTLRenderPipelineState> blur_ { nil };
    id<MTLRenderPipelineState> stretch_ { nil };
    id<MTLSamplerState>        sampler_ { nil };
    MTLPixelFormat             stretch_format_ { MTLPixelFormatInvalid };
    bool                       built_ { false };
    bool                       source_linear_ { false };
    std::unordered_map<uint32_t, id<MTLRenderPipelineState>> stretches_;

    /// What the reductions write, in order; the last is the small image that is blurred and
    /// later stretched. `scratch_` takes the horizontal blur on its way back into it.
    std::vector<id<MTLTexture>>                  chain_;
    id<MTLTexture>                               scratch_ { nil };
    std::vector<wallpaper::BackdropReductionStep> plan_;
    uint32_t                                     source_width_ { 0 };
    uint32_t                                     source_height_ { 0 };
    std::string                                  error_;
};

} // namespace wallpaper::metal
