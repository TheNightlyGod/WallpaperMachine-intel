#include "MetalUpscaler.hpp"

#include "MetalRender/MetalUpscaling.hpp"
#include "Utils/Logging.h"

#include <atomic>

namespace wallpaper::metal
{
namespace
{

/// Off by default: what a lowered render scale has always shown is the
/// bilinear stretch, and the extra pass is the user's to choose.
std::atomic<bool> g_upscaling_enabled { false };
std::atomic<bool> g_unsupported_for_tests { false };

/// The scene's colours are stored as they are shown, gamma and all, so an
/// 8-bit image is perceptual. A half-float one can hold light above 1 (bloom,
/// additive layers), which only the HDR mode keeps.
MTLFXSpatialScalerColorProcessingMode ProcessingModeFor(MTLPixelFormat format)
{
    return format == MTLPixelFormatRGBA16Float ? MTLFXSpatialScalerColorProcessingModeHDR
                                               : MTLFXSpatialScalerColorProcessingModePerceptual;
}

} // namespace

void SetMetalUpscalingEnabled(bool enabled)
{
    g_upscaling_enabled.store(enabled, std::memory_order_relaxed);
}

bool MetalUpscalingEnabled() { return g_upscaling_enabled.load(std::memory_order_relaxed); }

void SetMetalUpscalerUnsupportedForTests(bool unsupported)
{
    g_unsupported_for_tests.store(unsupported, std::memory_order_relaxed);
}

MetalUpscaler::MetalUpscaler()  = default;
MetalUpscaler::~MetalUpscaler() = default;

void MetalUpscaler::release()
{
    scaler_        = nil;
    output_        = nil;
    format_        = MTLPixelFormatInvalid;
    input_width_   = 0;
    input_height_  = 0;
    output_width_  = 0;
    output_height_ = 0;
    refused_       = false;
}

uint64_t MetalUpscaler::allocatedBytes() const
{
    return output_ != nil ? static_cast<uint64_t>(output_.allocatedSize) : 0;
}

bool MetalUpscaler::make(id<MTLDevice> device, id<MTLTexture> source, uint32_t width,
                         uint32_t height)
{
    scaler_ = nil;
    output_ = nil;
    if (g_unsupported_for_tests.load(std::memory_order_relaxed) ||
        ! [MTLFXSpatialScalerDescriptor supportsDevice:device]) {
        error_ = "MetalFX spatial scaling is not supported on this GPU";
        return false;
    }
    MTLFXSpatialScalerDescriptor* descriptor = [MTLFXSpatialScalerDescriptor new];
    descriptor.colorTextureFormat  = source.pixelFormat;
    descriptor.outputTextureFormat = source.pixelFormat;
    descriptor.inputWidth          = source.width;
    descriptor.inputHeight         = source.height;
    descriptor.outputWidth         = width;
    descriptor.outputHeight        = height;
    descriptor.colorProcessingMode = ProcessingModeFor(source.pixelFormat);
    id<MTLFXSpatialScaler> scaler  = [descriptor newSpatialScalerWithDevice:device];
    if (scaler == nil) {
        error_ = "MetalFX could not make a spatial scaler for this image";
        return false;
    }
    if ((source.usage & scaler.colorTextureUsage) != scaler.colorTextureUsage) {
        error_ = "the scene's output image cannot be read by MetalFX";
        return false;
    }

    MTLTextureDescriptor* image =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    // Read by the composition's sample, written only by the scaler.
    image.usage       = scaler.outputTextureUsage | MTLTextureUsageShaderRead;
    image.storageMode = MTLStorageModePrivate;
    id<MTLTexture> output = [device newTextureWithDescriptor:image];
    if (output == nil) {
        error_ = "the upscaled image could not be allocated";
        return false;
    }
    output.label = @"MetalFX upscaled scene output";
    scaler.outputTexture = output;
    scaler_              = scaler;
    output_              = output;
    error_.clear();
    return true;
}

id<MTLTexture> MetalUpscaler::encode(id<MTLDevice> device, id<MTLCommandBuffer> command,
                                     id<MTLTexture> source, uint32_t width, uint32_t height)
{
    if (device == nil || command == nil || source == nil || width == 0 || height == 0)
        return nil;
    const bool same = format_ == source.pixelFormat && input_width_ == source.width &&
                      input_height_ == source.height && output_width_ == width &&
                      output_height_ == height;
    if (! same) {
        format_        = source.pixelFormat;
        input_width_   = (uint32_t)source.width;
        input_height_  = (uint32_t)source.height;
        output_width_  = width;
        output_height_ = height;
        refused_       = ! make(device, source, width, height);
        if (refused_) {
            LOG_ERROR("metal render: MetalFX upscaling is off for this scene: %s",
                      error_.c_str());
        }
    }
    if (refused_ || scaler_ == nil) return nil;

    scaler_.colorTexture       = source;
    scaler_.inputContentWidth  = source.width;
    scaler_.inputContentHeight = source.height;
    [scaler_ encodeToCommandBuffer:command];
    // The command buffer holds the source now; the scaler must not keep a
    // released graph's image alive until the next frame replaces it.
    scaler_.colorTexture = nil;
    return output_;
}

} // namespace wallpaper::metal
