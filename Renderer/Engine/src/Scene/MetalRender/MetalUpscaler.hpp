#pragma once

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <cstdint>
#include <string>

namespace wallpaper::metal
{

/// The full-size picture of a scene drawn below full resolution, made by
/// MetalFX's spatial scaler from the scene's final output.
///
/// The scaler and its one output image exist only while a composition asks for
/// them: they are made on the first frame that needs them at a given input and
/// output size and format, and let go on the first composed frame that does
/// not. A combination MetalFX refuses is remembered, so a frame never retries
/// what the previous one could not do.
class MetalUpscaler {
public:
    MetalUpscaler();
    ~MetalUpscaler();
    MetalUpscaler(const MetalUpscaler&)            = delete;
    MetalUpscaler& operator=(const MetalUpscaler&) = delete;

    /// Encodes the upscale of `source` to `width` x `height` into `command` and
    /// returns the image it writes, or nil when MetalFX cannot do it; the caller
    /// then composes `source` itself.
    id<MTLTexture> encode(id<MTLDevice> device, id<MTLCommandBuffer> command,
                          id<MTLTexture> source, uint32_t width, uint32_t height);

    /// Releases the scaler and the image.
    void release();

    /// Bytes Metal allocated for the image that exists now.
    [[nodiscard]] uint64_t allocatedBytes() const;
    [[nodiscard]] bool hasImage() const { return output_ != nil; }
    [[nodiscard]] const std::string& error() const { return error_; }

private:
    bool make(id<MTLDevice> device, id<MTLTexture> source, uint32_t width, uint32_t height);

    id<MTLFXSpatialScaler> scaler_ { nil };
    id<MTLTexture>         output_ { nil };
    MTLPixelFormat         format_ { MTLPixelFormatInvalid };
    uint32_t               input_width_ { 0 };
    uint32_t               input_height_ { 0 };
    uint32_t               output_width_ { 0 };
    uint32_t               output_height_ { 0 };
    /// The combination `make` last failed for, so it is not tried every frame.
    bool                   refused_ { false };
    std::string            error_;
};

} // namespace wallpaper::metal
