#include "MetalBackdrop.hpp"

#include "Utils/Logging.h"

#include <algorithm>
#include <cmath>
#include <string_view>

namespace wallpaper::metal
{
namespace
{

// The blur is a Gaussian of sigma 3 texels cut off at 9, which holds all but a sliver of it.
constexpr int    kBlurRadius = 9;
constexpr double kBlurSigma  = 3.0;
constexpr float  kDarken     = 0.7f;

struct ReduceParams {
    float    inverse_size[2];
    uint32_t taps[2];
};

struct BlurParams {
    float step[2];
    float weights[kBlurRadius + 1];
};

struct StretchParams {
    float    image_size[2];
    uint32_t mirrored;
    float    brightness;
};

constexpr std::string_view kSource = R"(
#include <metal_stdlib>
using namespace metal;

struct Varying {
    float4 position [[position]];
    float2 texcoord;
};

// One triangle that covers the target; texcoord (0,0) is the top left, like the picture's own.
vertex Varying backdrop_vertex(uint vertex_id [[vertex_id]]) {
    const float2 corners[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    Varying out;
    out.position = float4(corners[vertex_id], 0.0, 1.0);
    out.texcoord = float2((corners[vertex_id].x + 1.0) * 0.5, (1.0 - corners[vertex_id].y) * 0.5);
    return out;
}

struct ReduceParams {
    float2 inverse_size;
    uint2  taps;
};

// A grid of bilinear taps spread evenly over the footprint of one destination texel.
fragment float4 backdrop_reduce(Varying in [[stage_in]],
                                texture2d<float> source [[texture(0)]],
                                sampler linear_clamp [[sampler(0)]],
                                constant ReduceParams& p [[buffer(0)]]) {
    float3 sum = float3(0.0);
    for (uint j = 0; j < p.taps.y; ++j) {
        for (uint i = 0; i < p.taps.x; ++i) {
            const float2 offset = ((float2(i, j) + 0.5) / float2(p.taps) - 0.5) * p.inverse_size;
            sum += source.sample(linear_clamp, in.texcoord + offset).rgb;
        }
    }
    return float4(sum / float(p.taps.x * p.taps.y), 1.0);
}

struct BlurParams {
    float2 step;
    float  weights[10];
};

fragment float4 backdrop_blur(Varying in [[stage_in]],
                              texture2d<float> source [[texture(0)]],
                              sampler linear_clamp [[sampler(0)]],
                              constant BlurParams& p [[buffer(0)]]) {
    float3 sum = source.sample(linear_clamp, in.texcoord).rgb * p.weights[0];
    for (int k = 1; k <= 9; ++k) {
        sum += source.sample(linear_clamp, in.texcoord + p.step * float(k)).rgb * p.weights[k];
        sum += source.sample(linear_clamp, in.texcoord - p.step * float(k)).rgb * p.weights[k];
    }
    return float4(sum, 1.0);
}

struct StretchParams {
    float2 image_size;
    uint   mirrored;
    float  brightness;
};

// Cubic B-spline filtering in four bilinear fetches: the four weights of the spline along an
// axis are merged in pairs, and each pair is read from the point between its two texels that
// gives their weighted mean.
float3 backdrop_color(Varying in, texture2d<float> source,
                      sampler linear_clamp, constant StretchParams& p) {
    float2 uv = in.texcoord;
    if (p.mirrored != 0) uv.x = 1.0 - uv.x;
    const float2 position = uv * p.image_size - 0.5;
    const float2 base     = floor(position);
    const float2 f        = position - base;
    const float2 f2       = f * f;
    const float2 f3       = f2 * f;
    const float2 w0       = (1.0 - f) * (1.0 - f) * (1.0 - f) / 6.0;
    const float2 w1       = (3.0 * f3 - 6.0 * f2 + 4.0) / 6.0;
    const float2 w2       = (-3.0 * f3 + 3.0 * f2 + 3.0 * f + 1.0) / 6.0;
    const float2 w3       = f3 / 6.0;
    const float2 g0       = w0 + w1;
    const float2 g1       = w2 + w3;
    const float2 h0       = (base + w1 / g0 - 1.0 + 0.5) / p.image_size;
    const float2 h1       = (base + w3 / g1 + 1.0 + 0.5) / p.image_size;

    float3 color = g0.y * (g0.x * source.sample(linear_clamp, float2(h0.x, h0.y)).rgb +
                           g1.x * source.sample(linear_clamp, float2(h1.x, h0.y)).rgb) +
                   g1.y * (g0.x * source.sample(linear_clamp, float2(h0.x, h1.y)).rgb +
                           g1.x * source.sample(linear_clamp, float2(h1.x, h1.y)).rgb);
    color *= p.brightness;

    return color;
}
float backdrop_dither(Varying in) {
    // A 4x4 ordered (Bayer) pattern worth one 8-bit step, fixed by the pixel it lands on.
    const uint2 cell = uint2(in.position.xy) & 3u;
    const uint  bayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
    const float dither = ((float(bayer[cell.y * 4u + cell.x]) + 0.5) / 16.0 - 0.5) / 255.0;
    return dither;
}
float3 backdrop_encode(float3 c) {
    c = saturate(c);
    return select(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055,
                  c > float3(0.0031308));
}
float3 backdrop_decode(float3 c) {
    c = max(c, float3(0.0));
    return select(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), c > float3(0.04045));
}
fragment float4 backdrop_stretch(Varying in [[stage_in]], texture2d<float> source [[texture(0)]],
    sampler s [[sampler(0)]], constant StretchParams& p [[buffer(0)]]) {
    return float4(saturate(backdrop_color(in,source,s,p) + backdrop_dither(in)),1.0);
}
fragment float4 backdrop_stretch_encode(Varying in [[stage_in]], texture2d<float> source [[texture(0)]],
    sampler s [[sampler(0)]], constant StretchParams& p [[buffer(0)]]) {
    return float4(saturate(backdrop_encode(backdrop_color(in,source,s,p)) + backdrop_dither(in)),1.0);
}
fragment float4 backdrop_stretch_linear(Varying in [[stage_in]], texture2d<float> source [[texture(0)]],
    sampler s [[sampler(0)]], constant StretchParams& p [[buffer(0)]]) {
    return float4(max(backdrop_color(in,source,s,p),float3(0.0)),1.0);
}
fragment float4 backdrop_stretch_decode(Varying in [[stage_in]], texture2d<float> source [[texture(0)]],
    sampler s [[sampler(0)]], constant StretchParams& p [[buffer(0)]]) {
    return float4(backdrop_decode(backdrop_color(in,source,s,p)),1.0);
}
)";

id<MTLRenderPipelineState> MakePipeline(id<MTLDevice> device, id<MTLLibrary> library, NSString* fragment,
                                        MTLPixelFormat format, NSString* label, std::string* error)
{
    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label                            = label;
    descriptor.vertexFunction                   = [library newFunctionWithName:@"backdrop_vertex"];
    descriptor.fragmentFunction                 = [library newFunctionWithName:fragment];
    descriptor.colorAttachments[0].pixelFormat  = format;
    NSError*                   failure  = nil;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&failure];
    if (pipeline == nil) {
        *error = std::string("the backdrop pipeline ") + label.UTF8String + " failed to build: " +
                 (failure != nil ? failure.localizedDescription.UTF8String : "unknown error");
    }
    return pipeline;
}

id<MTLTexture> MakeImage(id<MTLDevice> device, uint32_t width, uint32_t height, MTLPixelFormat format,
                         NSString* label)
{
    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    texture.label          = label;
    return texture;
}

/// One full-target draw of `pipeline`, reading `source`, into `destination`.
id<MTLRenderCommandEncoder> BeginPass(id<MTLCommandBuffer> command, id<MTLTexture> destination,
                                      id<MTLRenderPipelineState> pipeline, id<MTLTexture> source,
                                      id<MTLSamplerState> sampler, NSString* label)
{
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture     = destination;
    // Every texel is drawn, so nothing is loaded.
    pass.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    if (encoder == nil) return nil;
    encoder.label = label;
    [encoder setViewport:(MTLViewport) { 0.0, 0.0, (double)destination.width, (double)destination.height, 0.0, 1.0 }];
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder setFragmentSamplerState:sampler atIndex:0];
    return encoder;
}

} // namespace

MetalBackdrop::MetalBackdrop()  = default;
MetalBackdrop::~MetalBackdrop() = default;

bool MetalBackdrop::buildPipelines(id<MTLDevice> device, MTLPixelFormat destination, bool source_linear)
{
    if (built_ && device == device_ && destination == stretch_format_ && source_linear == source_linear_)
        return true;
    if (device == nil) return false;
    if (!built_ || device != device_) {
        release();
        NSString* source = [[NSString alloc] initWithBytes:kSource.data() length:kSource.size()
                                                encoding:NSUTF8StringEncoding];
        NSError* failure = nil;
        library_ = [device newLibraryWithSource:source options:[MTLCompileOptions new] error:&failure];
        if (library_ == nil) {
            error_ = std::string("the backdrop shaders failed to compile: ") +
                (failure != nil ? failure.localizedDescription.UTF8String : "unknown error");
            return false;
        }
        MTLSamplerDescriptor* descriptor = [MTLSamplerDescriptor new];
        descriptor.minFilter = descriptor.magFilter = MTLSamplerMinMagFilterLinear;
        descriptor.sAddressMode = descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sampler_ = [device newSamplerStateWithDescriptor:descriptor];
        reduce_8bit_ = MakePipeline(device, library_, @"backdrop_reduce", MTLPixelFormatRGBA8Unorm,
                                   @"Backdrop reduction (8-bit)", &error_);
        reduce_half_ = MakePipeline(device, library_, @"backdrop_reduce", MTLPixelFormatRGBA16Float,
                                   @"Backdrop reduction", &error_);
        blur_ = MakePipeline(device, library_, @"backdrop_blur", MTLPixelFormatRGBA16Float,
                             @"Backdrop blur", &error_);
        if (sampler_ == nil || reduce_8bit_ == nil || reduce_half_ == nil || blur_ == nil) return false;
        device_ = device;
        built_ = true;
    }
    const bool destination_linear = destination == MTLPixelFormatRGBA16Float ||
        destination == MTLPixelFormatBGRA8Unorm_sRGB || destination == MTLPixelFormatRGBA8Unorm_sRGB;
    NSString* fragment = source_linear
        ? (destination_linear ? @"backdrop_stretch_linear" : @"backdrop_stretch_encode")
        : (destination_linear ? @"backdrop_stretch_decode" : @"backdrop_stretch");
    const uint32_t key = static_cast<uint32_t>(destination) | (source_linear ? 0x10000u : 0u);
    auto found = stretches_.find(key);
    if (found == stretches_.end()) {
        auto pipeline = MakePipeline(device, library_, fragment, destination, @"Backdrop stretch", &error_);
        if (pipeline == nil) return false;
        found = stretches_.emplace(key, pipeline).first;
    }
    if (source_linear_ != source_linear) releaseImages();
    source_linear_ = source_linear;
    stretch_ = found->second;
    stretch_format_ = destination;
    error_.clear();
    return true;
}

bool MetalBackdrop::canDraw(MTLPixelFormat destination) const
{
    return built_ && destination == stretch_format_;
}

void MetalBackdrop::release()
{
    releaseImages();
    reduce_8bit_    = nil;
    reduce_half_    = nil;
    blur_           = nil;
    stretch_        = nil;
    stretches_.clear();
    source_linear_ = false;
    sampler_        = nil;
    library_        = nil;
    device_         = nil;
    stretch_format_ = MTLPixelFormatInvalid;
    built_          = false;
}

void MetalBackdrop::releaseImages()
{
    chain_.clear();
    scratch_       = nil;
    plan_.clear();
    source_width_  = 0;
    source_height_ = 0;
}

bool MetalBackdrop::makeImages(uint32_t source_width, uint32_t source_height)
{
    if (!chain_.empty() && source_width == source_width_ && source_height == source_height_) return true;
    releaseImages();

    auto plan = wallpaper::PlanBackdropReduction(source_width, source_height);
    std::vector<id<MTLTexture>> chain;
    for (auto& step : plan) {
        if (source_linear_) step.eight_bit = false;
        id<MTLTexture> image = MakeImage(device_, step.width, step.height,
                                         step.eight_bit ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA16Float,
                                         step.eight_bit ? @"Backdrop eighth" : @"Backdrop small image");
        if (image == nil) {
            error_ = "the backdrop images could not be allocated";
            return false;
        }
        chain.push_back(image);
    }
    id<MTLTexture> scratch = MakeImage(device_, plan.back().width, plan.back().height,
                                       MTLPixelFormatRGBA16Float, @"Backdrop blur scratch");
    if (scratch == nil) {
        error_ = "the backdrop images could not be allocated";
        return false;
    }
    chain_         = std::move(chain);
    scratch_       = scratch;
    plan_          = std::move(plan);
    source_width_  = source_width;
    source_height_ = source_height;
    return true;
}

bool MetalBackdrop::encodeMaking(id<MTLCommandBuffer> command, id<MTLTexture> source)
{
    if (!built_ || command == nil || source == nil) return false;
    if (!makeImages((uint32_t)source.width, (uint32_t)source.height)) return false;

    [command pushDebugGroup:@"Fit with blurred backdrop"];
    id<MTLTexture> from = source;
    for (std::size_t i = 0; i < plan_.size(); ++i) {
        const auto& step = plan_[i];
        id<MTLRenderCommandEncoder> encoder =
            BeginPass(command, chain_[i], step.eight_bit ? reduce_8bit_ : reduce_half_, from, sampler_,
                      step.eight_bit ? @"Backdrop reduction (8-bit)" : @"Backdrop reduction");
        if (encoder == nil) {
            [command popDebugGroup];
            return false;
        }
        const ReduceParams params { { 1.0f / (float)from.width, 1.0f / (float)from.height },
                                    { step.taps_x, step.taps_y } };
        [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        from = chain_[i];
    }

    // Normalised weights of the Gaussian; the centre tap and each side's taps share them.
    BlurParams horizontal {};
    double     total = 0.0;
    for (int k = 0; k <= kBlurRadius; ++k) {
        const double w = std::exp(-(double)(k * k) / (2.0 * kBlurSigma * kBlurSigma));
        horizontal.weights[k] = (float)w;
        total += k == 0 ? w : 2.0 * w;
    }
    for (float& w : horizontal.weights) w = (float)(w / total);
    BlurParams vertical = horizontal;

    id<MTLTexture> small = chain_.back();
    horizontal.step[0] = 1.0f / (float)small.width;
    horizontal.step[1] = 0.0f;
    vertical.step[0]   = 0.0f;
    vertical.step[1]   = 1.0f / (float)small.height;
    const struct { id<MTLTexture> from, to; const BlurParams* params; NSString* label; } blurs[2] = {
        { small, scratch_, &horizontal, @"Backdrop blur, horizontal" },
        { scratch_, small, &vertical, @"Backdrop blur, vertical" },
    };
    for (const auto& blur : blurs) {
        id<MTLRenderCommandEncoder> encoder = BeginPass(command, blur.to, blur_, blur.from, sampler_, blur.label);
        if (encoder == nil) {
            [command popDebugGroup];
            return false;
        }
        [encoder setFragmentBytes:blur.params length:sizeof(BlurParams) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
    }
    [command popDebugGroup];
    return true;
}

void MetalBackdrop::encodeBands(id<MTLRenderCommandEncoder> encoder, const SurroundBands& bands,
                                const MTLViewport& viewport, bool mirrored) const
{
    if (!built_ || chain_.empty() || bands.count <= 0) return;
    id<MTLTexture> small = chain_.back();
    [encoder pushDebugGroup:@"Fit with blurred backdrop: bands"];
    [encoder setViewport:viewport];
    [encoder setRenderPipelineState:stretch_];
    [encoder setFragmentTexture:small atIndex:0];
    [encoder setFragmentSamplerState:sampler_ atIndex:0];
    const StretchParams params { { (float)small.width, (float)small.height }, mirrored ? 1u : 0u, kDarken };
    [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
    for (int i = 0; i < bands.count; ++i) {
        const PixelRect& band = bands.rects[i];
        [encoder setScissorRect:(MTLScissorRect) { (NSUInteger)band.x, (NSUInteger)band.y,
                                                   (NSUInteger)band.width, (NSUInteger)band.height }];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [encoder popDebugGroup];
}

uint64_t MetalBackdrop::allocatedBytes() const
{
    uint64_t bytes = 0;
    for (id<MTLTexture> image : chain_) bytes += image.allocatedSize;
    if (scratch_ != nil) bytes += scratch_.allocatedSize;
    return bytes;
}

} // namespace wallpaper::metal
