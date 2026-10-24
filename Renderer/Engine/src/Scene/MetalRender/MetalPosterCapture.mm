#include "MetalPosterCapture.hpp"

#include "Utils/Logging.h"

#include <atomic>
#include <cstddef>
#include <mutex>
#include <utility>
#include <vector>

namespace wallpaper::metal
{
namespace
{

/// The host PNG-encodes the poster on its own thread, so the bytes are copied
/// once more before they are consumed. A display this large is refused: it is not worth the
/// transient allocation a still image costs.
constexpr std::size_t kMaxPosterBytes = 128u * 1024u * 1024u;

bool IsBGRA(MTLPixelFormat format)
{
    return format == MTLPixelFormatBGRA8Unorm || format == MTLPixelFormatBGRA8Unorm_sRGB;
}

bool IsSupportedFormat(MTLPixelFormat format)
{
    return IsBGRA(format) || format == MTLPixelFormatRGBA8Unorm ||
           format == MTLPixelFormatRGBA8Unorm_sRGB;
}

} // namespace

struct MetalPosterCapture::State
{
    std::mutex  mutex;
    PosterReady ready; // guarded by `mutex`; the handler may read it at any time

    /// Bumped by `invalidate()`. A handler whose capture was started before the
    /// bump has nothing meaningful to deliver -- the surface it composed for is
    /// gone -- so it drops its result instead of calling back into a host that
    /// has moved on.
    std::atomic<uint64_t> generation { 0 };
    std::atomic<bool>     in_flight { false };
};

MetalPosterCapture::MetalPosterCapture() : state_(std::make_shared<State>()) {}

MetalPosterCapture::~MetalPosterCapture() { invalidate(); }

void MetalPosterCapture::configure(id<MTLDevice> device, WantsPoster wants, PosterReady ready)
{
    // Reconfiguring means the surface was reset: anything already in flight was
    // composed for the old one.
    invalidate();
    device_ = device;
    wants_  = std::move(wants);
    std::lock_guard<std::mutex> guard(state_->mutex);
    state_->ready = std::move(ready);
}

void MetalPosterCapture::invalidate()
{
    state_->generation.fetch_add(1, std::memory_order_acq_rel);
    // Cleared here rather than left to the handler: a capture that is dropped
    // must not leave the next request answered with `Busy` forever. The handler
    // only clears the flag while its own generation is still current, so this
    // can never release a flag a later capture has taken.
    state_->in_flight.store(false, std::memory_order_release);
}

MetalPosterCapture::Outcome MetalPosterCapture::fail(std::string message)
{
    last_error_ = std::move(message);
    LOG_ERROR("metal poster: %s", last_error_.c_str());
    return Outcome::Failed;
}

MetalPosterCapture::Outcome MetalPosterCapture::encodeIfRequested(id<MTLCommandBuffer> command,
                                                                 uint32_t width, uint32_t height,
                                                                 MTLPixelFormat format,
                                                                 const EncodeComposition& encode)
{
    if (device_ == nil || command == nil || ! wants_) return Outcome::NotRequested;
    {
        std::lock_guard<std::mutex> guard(state_->mutex);
        if (! state_->ready) return Outcome::NotRequested;
    }

    // Asked before `wants()`, because `wants()` has side effects on the host: it
    // takes the pending request and arms its retry backoff. Answering `Busy`
    // without consuming the request is what bounds concurrent captures to one
    // and lets the next call serve whatever the host still wants.
    if (state_->in_flight.load(std::memory_order_acquire)) return Outcome::Busy;

    if (width == 0 || height == 0) {
        return fail("poster size " + std::to_string(width) + "x" + std::to_string(height) +
                    " is empty");
    }
    const std::size_t bytes = static_cast<std::size_t>(width) * height * 4u;
    if (bytes > kMaxPosterBytes) {
        return fail("poster of " + std::to_string(width) + "x" + std::to_string(height) +
                    " needs " + std::to_string(bytes) + " bytes, over the " +
                    std::to_string(kMaxPosterBytes) + " byte limit");
    }
    if (! IsSupportedFormat(format)) {
        return fail("poster pixel format " + std::to_string(static_cast<uint64_t>(format)) +
                    " is not an 8-bit BGRA or RGBA format");
    }

    if (! wants_()) return Outcome::NotRequested;

    const uint64_t generation = state_->generation.load(std::memory_order_acquire);
    state_->in_flight.store(true, std::memory_order_release);

    // Allocated per request and released when the handler's block is destroyed:
    // a full-screen texture kept alive between posters would cost the wallpaper
    // that memory permanently, for an image the host asks for rarely.
    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget;
    // Unified memory is the only configuration this app ships on; the managed
    // path exists so a discrete device still reads back correct pixels rather
    // than stale ones.
    const bool unified = device_.hasUnifiedMemory;
    descriptor.storageMode = unified ? MTLStorageModeShared : MTLStorageModeManaged;

    id<MTLTexture> texture = [device_ newTextureWithDescriptor:descriptor];
    if (texture == nil) {
        state_->in_flight.store(false, std::memory_order_release);
        return fail("poster texture could not be allocated");
    }

    if (! encode || ! encode(command, texture)) {
        texture = nil;
        state_->in_flight.store(false, std::memory_order_release);
        return fail("the final composition could not be encoded into the poster texture");
    }

    if (! unified) {
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        [blit synchronizeResource:texture];
        [blit endEncoding];
    }

    auto state = state_;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        // Metal-owned thread, possibly after the renderer is gone. Only `state`
        // and the texture are touched, and both are kept alive by this block.
        if (completed.status != MTLCommandBufferStatusCompleted) {
            if (state->generation.load(std::memory_order_acquire) == generation) {
                state->in_flight.store(false, std::memory_order_release);
            }
            return;
        }
        if (state->generation.load(std::memory_order_acquire) != generation) return;

        std::vector<uint8_t> pixels(bytes);
        [texture getBytes:pixels.data()
              bytesPerRow:static_cast<NSUInteger>(width) * 4u
               fromRegion:MTLRegionMake2D(0, 0, width, height)
              mipmapLevel:0];

        PosterReady ready;
        {
            std::lock_guard<std::mutex> guard(state->mutex);
            // Re-checked under the lock so the callback cannot be replaced
            // between the test and the call.
            if (state->generation.load(std::memory_order_acquire) == generation) {
                ready = state->ready;
            }
        }
        // Handed over exactly as stored: no channel swap and no sRGB
        // conversion. The flag describes the bytes, and the host encodes them
        // accordingly, which is what keeps the poster's colours identical to
        // the frame that was presented.
        if (ready) ready(std::span<const uint8_t>(pixels.data(), pixels.size()), width, height,
                         IsBGRA(format));
        if (state->generation.load(std::memory_order_acquire) == generation) {
            state->in_flight.store(false, std::memory_order_release);
        }
    }];

    return Outcome::Encoded;
}

const std::string& MetalPosterCapture::lastError() const { return last_error_; }

} // namespace wallpaper::metal
