// A VTDecompressionSession behind a small C++ interface: compressed samples go
// in, decoded Core Video pixel buffers come out in display order.
//
// Written from Apple's VideoToolbox headers. What it takes care of:
//   * Output is IOSurface-backed and Metal-compatible, biplanar 4:2:0 (NV12
//     video range for 8-bit, 'x420' for 10-bit), so a frame reaches the GPU
//     without a copy.
//   * Frames are decoded asynchronously and may complete in decode order; the
//     wrapper holds them in a buffer sized from the stream's own reordering and
//     releases them in display order, whatever the codec or the decoder does.
//   * Seeking is an epoch: `reset()` starts a new one, and whatever the decoder
//     still delivers from the old one is dropped on arrival.
//   * Work in flight and frames waiting are both bounded, so a slow consumer
//     stops the decoder instead of growing memory.
//   * A frame the decoder fails on is skipped (a leading picture after a seek
//     can reference what was never decoded); only a decoder that keeps failing
//     fails the stream.
#pragma once

#include "Media/Apple/FormatDescription.hpp"
#include "Media/VideoTypes.hpp"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace wallpaper::media::apple
{

/// A retained CVPixelBufferRef. Move only; releasing drops one reference.
class PixelBuffer {
public:
    PixelBuffer() = default;
    /// Adopts one retained reference.
    explicit PixelBuffer(void* retained) : m_buffer(retained) {}
    PixelBuffer(PixelBuffer&& other) noexcept : m_buffer(other.m_buffer) { other.m_buffer = nullptr; }
    PixelBuffer& operator=(PixelBuffer&& other) noexcept;
    PixelBuffer(const PixelBuffer&) = delete;
    PixelBuffer& operator=(const PixelBuffer&) = delete;
    ~PixelBuffer();

    void* get() const { return m_buffer; }
    explicit operator bool() const { return m_buffer != nullptr; }
    /// Gives the reference up without releasing it; the caller owns it now.
    void* release()
    {
        void* buffer = m_buffer;
        m_buffer     = nullptr;
        return buffer;
    }

private:
    void* m_buffer { nullptr };
};

struct DecodedFrame {
    PixelBuffer pixels;
    /// The presentation time the sample was submitted with, in the stream's ticks.
    std::int64_t pts { 0 };
};

struct SampleTiming {
    std::int64_t pts { 0 };
    std::int64_t dts { 0 };
    std::int64_t duration { 0 };
};

struct DecoderOptions {
    /// Samples submitted and not yet decoded. Two keep the decoder's hardware
    /// busy: a 4K 60 fps clip decodes at the same speed with two in flight as with
    /// eight, and about a quarter slower with one. Every one more is another
    /// decoded picture allocated before anything wants it.
    std::size_t maxInFlight { 2 };
    /// Decoded frames held for the consumer, beyond what display-order delivery
    /// itself needs (`ReorderDepth + 1`).
    std::size_t extraBuffered { 1 };
};

/// The deepest reordering a stream may need. H.264 and HEVC allow at most 16
/// pictures in the decoded picture buffer, and the FFmpeg path was bounded at 16
/// delayed pictures; a sample table that asks for more is damaged or hostile, and
/// holding that many decoded pictures (12 MB each at 4K) would let an untrusted
/// file exhaust memory. `Create` refuses a deeper stream.
inline constexpr std::size_t kMaxReorderDepth = 16;

class VtFrameDecoder {
public:
    enum class SubmitResult {
        Accepted,
        /// The decoder is at its bound; take output and submit again.
        Full,
        Failed,
    };
    enum class ReceiveResult {
        Frame,
        /// Nothing is ready (within the wait given).
        NotReady,
        /// After `drain()`: every frame has been delivered.
        EndOfStream,
        Failed,
    };

    /// Opens a decoder for `format` (from MakeStreamFormat). `reorderDepth` is
    /// ReorderDepth() of the stream's sample table. Returns null with `*error`
    /// set when the session cannot be created: VideoToolbox has no decoder for
    /// the stream (the message begins with `kFormatNotSupported`), or the stream
    /// reorders deeper than `kMaxReorderDepth` (a message about the sample table).
    static std::unique_ptr<VtFrameDecoder> Create(StreamFormat format, std::int64_t timescale,
                                                  std::size_t reorderDepth, const DecoderOptions& options,
                                                  std::string* error);
    ~VtFrameDecoder();

    VtFrameDecoder(const VtFrameDecoder&) = delete;
    VtFrameDecoder& operator=(const VtFrameDecoder&) = delete;

    /// Submits one compressed sample. Never blocks on the decoder's work, only
    /// briefly on the call itself.
    SubmitResult submit(const std::uint8_t* data, std::size_t size, const SampleTiming& timing, bool sync,
                        std::string* error);

    /// The next decoded frame in display order. Waits up to `wait` for one when
    /// none is ready and more are expected.
    ReceiveResult receive(DecodedFrame* out, std::chrono::milliseconds wait, std::string* error);

    /// Marks the end of input and flushes what the decoder holds: frames still
    /// owed are delivered, then `receive` reports `EndOfStream`. Blocks until the
    /// decoder has finished the samples it was given.
    bool drain(std::string* error);

    /// Starts a new epoch (a seek, or the next loop): frames waiting and frames
    /// still in the decoder are dropped. Blocks until the decoder has finished
    /// the samples already in flight.
    bool reset(std::string* error);

    /// Makes waiting calls return promptly and refuses further submissions.
    /// Callable from any thread; latched.
    void cancel();

    /// The pixel format frames arrive in.
    std::uint32_t pixelFormat() const;
    /// Whether VideoToolbox picked a hardware decoder.
    bool usingHardware() const;
    /// Frames dropped because their decode failed or came from a past epoch.
    std::uint64_t skippedFrames() const;
    /// Frames the callback delivered in an order other than display order before
    /// reordering: a diagnostic that tells whether the decoder reordered itself.
    std::uint64_t outOfOrderCompletions() const;

    /// The decoder's state; opaque, public only so the session's callback can name it.
    struct Impl;

private:
    explicit VtFrameDecoder(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> m_impl;
};

} // namespace wallpaper::media::apple
