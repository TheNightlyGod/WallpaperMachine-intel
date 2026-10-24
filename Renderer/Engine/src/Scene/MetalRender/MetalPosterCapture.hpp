#pragma once

#import <Metal/Metal.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <span>
#include <string>

namespace wallpaper::metal
{

/// Delivers the host's "desktop poster": a still of the wallpaper this backend
/// is itself drawing. The pixels always come from a texture this class owns and
/// the renderer draws into -- never from a drawable, another window or the
/// desktop -- so a capture can never observe anything the app did not render.
class MetalPosterCapture {
public:
    using WantsPoster = std::function<bool()>;
    using PosterReady = std::function<void(std::span<const uint8_t>, uint32_t, uint32_t, bool)>;
    /// Draws the final composition into `destination`, encoded into `command`.
    /// Returns false if it could not.
    using EncodeComposition = std::function<bool(id<MTLCommandBuffer> command,
                                                 id<MTLTexture> destination)>;
    enum class Outcome
    {
        NotRequested,
        Encoded,
        Busy,
        Failed
    };

    MetalPosterCapture();
    ~MetalPosterCapture();
    MetalPosterCapture(const MetalPosterCapture&)            = delete;
    MetalPosterCapture& operator=(const MetalPosterCapture&) = delete;

    void configure(id<MTLDevice> device, WantsPoster wants, PosterReady ready);
    /// Surface released/reset, graph cleared, backend destroyed: results of
    /// captures still in flight are dropped.
    void invalidate();
    /// Render thread. Caller commits `command` afterwards when the outcome is
    /// Encoded.
    Outcome encodeIfRequested(id<MTLCommandBuffer> command, uint32_t width, uint32_t height,
                              MTLPixelFormat format, const EncodeComposition& encode);
    [[nodiscard]] const std::string& lastError() const;

private:
    /// Everything the completion handler touches. Held by `shared_ptr` because
    /// the handler runs on a Metal-owned thread and may outlive this object.
    struct State;

    Outcome fail(std::string message);

    id<MTLDevice>          device_ { nil };
    WantsPoster            wants_;
    std::shared_ptr<State> state_;
    std::string            last_error_;
};

} // namespace wallpaper::metal
