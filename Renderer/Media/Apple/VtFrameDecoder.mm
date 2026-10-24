#include "Media/Apple/VtFrameDecoder.hpp"

#import <CoreFoundation/CoreFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <queue>
#include <vector>

namespace wallpaper::media::apple
{

PixelBuffer& PixelBuffer::operator=(PixelBuffer&& other) noexcept
{
    if (this != &other) {
        if (m_buffer != nullptr) CFRelease(m_buffer);
        m_buffer       = other.m_buffer;
        other.m_buffer = nullptr;
    }
    return *this;
}

PixelBuffer::~PixelBuffer()
{
    if (m_buffer != nullptr) CFRelease(m_buffer);
}

namespace
{

/// Consecutive frames the decoder may fail before the stream is failed.
constexpr std::uint32_t kMaxConsecutiveFailures = 90;

std::string StatusText(OSStatus status)
{
    return "OSStatus " + std::to_string(static_cast<int>(status));
}

/// The refcon of a sample: which epoch it belongs to, and its place in submission order.
constexpr std::uintptr_t kEpochBits = 16;
std::uintptr_t PackRefCon(std::uint64_t epoch, std::uint64_t sequence)
{
    return (static_cast<std::uintptr_t>(sequence) << kEpochBits) |
           (static_cast<std::uintptr_t>(epoch) & ((std::uintptr_t { 1 } << kEpochBits) - 1));
}

struct HeldFrame {
    CVPixelBufferRef buffer;
    std::int64_t     pts;
};

struct LaterPts {
    bool operator()(const HeldFrame& a, const HeldFrame& b) const { return a.pts > b.pts; }
};

} // namespace

struct VtFrameDecoder::Impl {
    StreamFormat          format;
    std::int32_t          timescale { 1 };
    std::size_t           reorderDepth { 0 };
    DecoderOptions        options;
    VTDecompressionSessionRef session { nullptr };
    bool                  hardware { false };

    mutable std::mutex      mutex;
    std::condition_variable changed;
    /// Decoded, awaiting the reorder rule.
    std::priority_queue<HeldFrame, std::vector<HeldFrame>, LaterPts> held;
    /// Ready for the consumer, in display order.
    std::deque<HeldFrame> ready;
    std::size_t           inFlight { 0 };
    std::uint64_t         epoch { 0 };
    std::uint64_t         submitted { 0 };
    std::uint64_t         lastCompleted { 0 };
    bool                  draining { false };
    std::uint32_t         consecutiveFailures { 0 };
    std::atomic<bool>     cancelled { false };
    bool                  failed { false };
    std::string           failure;
    std::uint64_t         skipped { 0 };
    std::uint64_t         outOfOrder { 0 };

    ~Impl()
    {
        for (const HeldFrame& frame : ready) CFRelease(frame.buffer);
        while (! held.empty()) {
            CFRelease(held.top().buffer);
            held.pop();
        }
    }

    [[nodiscard]] std::size_t bufferedLocked() const { return held.size() + ready.size(); }
    [[nodiscard]] std::size_t maxBuffered() const { return reorderDepth + 1 + options.extraBuffered; }

    /// Moves frames the reorder rule has cleared into the ready queue. With
    /// `all`, everything (the end of the stream).
    void releaseHeldLocked(bool all)
    {
        while (! held.empty() && (all || held.size() > reorderDepth)) {
            ready.push_back(held.top());
            held.pop();
        }
    }

    void dropAllLocked()
    {
        for (const HeldFrame& frame : ready) CFRelease(frame.buffer);
        ready.clear();
        while (! held.empty()) {
            CFRelease(held.top().buffer);
            held.pop();
        }
    }

    void fail(std::string message)
    {
        std::lock_guard lock(mutex);
        failLocked(std::move(message));
    }

    void failLocked(std::string message)
    {
        if (! failed) {
            failed  = true;
            failure = std::move(message);
        }
        changed.notify_all();
    }

    void complete(void* sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef image,
                  CMTime pts)
    {
        const auto packed = reinterpret_cast<std::uintptr_t>(sourceFrameRefCon);
        const std::uint64_t frameEpoch = packed & ((std::uintptr_t { 1 } << kEpochBits) - 1);
        const std::uint64_t sequence   = packed >> kEpochBits;

        std::lock_guard lock(mutex);
        if (inFlight > 0) --inFlight;
        if (sequence < lastCompleted) ++outOfOrder;
        lastCompleted = std::max(lastCompleted, sequence);

        const bool current = frameEpoch == (epoch & ((std::uint64_t { 1 } << kEpochBits) - 1));
        if (! current) {
            ++skipped;
        } else if (status != noErr) {
            ++skipped;
            if (++consecutiveFailures >= kMaxConsecutiveFailures) {
                failLocked("the video decoder keeps failing (" + StatusText(status) + ")");
            }
        } else if (image == nullptr || (flags & kVTDecodeInfo_FrameDropped) != 0) {
            // A frame the codec does not show (a hidden AV1 or VP9 frame): nothing to deliver.
        } else {
            consecutiveFailures = 0;
            CFRetain(image);
            const CMTime ticks = pts.timescale == timescale
                ? pts
                : CMTimeConvertScale(pts, timescale, kCMTimeRoundingMethod_Default);
            held.push({ image, ticks.value });
            releaseHeldLocked(false);
        }
        changed.notify_all();
    }
};

namespace
{

void OutputCallback(void* decompressionOutputRefCon, void* sourceFrameRefCon, OSStatus status,
                    VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer, CMTime presentationTimeStamp,
                    CMTime presentationDuration)
{
    (void) presentationDuration;
    auto* impl = static_cast<VtFrameDecoder::Impl*>(decompressionOutputRefCon);
    impl->complete(sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp);
}

} // namespace

VtFrameDecoder::VtFrameDecoder(std::unique_ptr<Impl> impl) : m_impl(std::move(impl)) {}

std::unique_ptr<VtFrameDecoder> VtFrameDecoder::Create(StreamFormat format, std::int64_t timescale,
                                                       std::size_t reorderDepth, const DecoderOptions& options,
                                                       std::string* error)
{
    const auto refuse = [&](const std::string& message) -> std::unique_ptr<VtFrameDecoder> {
        if (error != nullptr) *error = message;
        return nullptr;
    };
    if (! format.description) return refuse("no format description");
    if (timescale <= 0 || timescale > 0x7fffffff) return refuse("the video's time scale is out of range");
    if (reorderDepth > kMaxReorderDepth) {
        return refuse("the video's sample table reorders " + std::to_string(reorderDepth) +
                      " frames, more than the " + std::to_string(kMaxReorderDepth) + " a decoder may hold");
    }

    auto impl          = std::make_unique<Impl>();
    impl->timescale    = static_cast<std::int32_t>(timescale);
    impl->reorderDepth = reorderDepth;
    impl->options      = options;
    impl->options.maxInFlight = std::max<std::size_t>(1, options.maxInFlight);
    impl->format       = std::move(format);

    @autoreleasepool {
        NSDictionary* destination = @{
            (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey : @(impl->format.pixelFormat),
            (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
            (__bridge NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
        };
        NSDictionary* specification = @{
            (__bridge NSString*)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder : @YES,
        };
        VTDecompressionOutputCallbackRecord callback { OutputCallback, impl.get() };
        VTDecompressionSessionRef           session = nullptr;
        const OSStatus status = VTDecompressionSessionCreate(
            kCFAllocatorDefault, static_cast<CMVideoFormatDescriptionRef>(impl->format.description.get()),
            (__bridge CFDictionaryRef)specification, (__bridge CFDictionaryRef)destination, &callback, &session);
        if (status != noErr || session == nullptr) {
            return refuse(std::string(kFormatNotSupported) + "VideoToolbox has no decoder for this video (" +
                          StatusText(status) + ")");
        }
        impl->session = session;

        CFTypeRef hardware = nullptr;
        if (VTSessionCopyProperty(session, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  kCFAllocatorDefault, &hardware) == noErr && hardware != nullptr) {
            impl->hardware = CFBooleanGetValue(static_cast<CFBooleanRef>(hardware));
            CFRelease(hardware);
        }
    }
    return std::unique_ptr<VtFrameDecoder>(new VtFrameDecoder(std::move(impl)));
}

VtFrameDecoder::~VtFrameDecoder()
{
    Impl& impl = *m_impl;
    impl.cancelled.store(true);
    if (impl.session != nullptr) {
        // Frames still being decoded call back into `impl`: let them finish first.
        VTDecompressionSessionWaitForAsynchronousFrames(impl.session);
        VTDecompressionSessionInvalidate(impl.session);
        CFRelease(impl.session);
        impl.session = nullptr;
    }
    // A callback that was already running holds the mutex until it is done.
    std::unique_lock lock(impl.mutex);
    impl.changed.wait_for(lock, std::chrono::seconds(2), [&impl] { return impl.inFlight == 0; });
}

VtFrameDecoder::SubmitResult VtFrameDecoder::submit(const std::uint8_t* data, std::size_t size,
                                                    const SampleTiming& timing, bool sync, std::string* error)
{
    Impl& impl = *m_impl;
    std::uint64_t epoch = 0;
    std::uint64_t sequence = 0;
    {
        std::lock_guard lock(impl.mutex);
        if (impl.failed) {
            if (error != nullptr) *error = impl.failure;
            return SubmitResult::Failed;
        }
        if (impl.cancelled.load()) return SubmitResult::Failed;
        if (impl.inFlight >= impl.options.maxInFlight || impl.bufferedLocked() >= impl.maxBuffered()) {
            return SubmitResult::Full;
        }
        ++impl.inFlight;
        epoch    = impl.epoch;
        sequence = ++impl.submitted;
    }

    const auto undo = [&impl] {
        std::lock_guard lock(impl.mutex);
        if (impl.inFlight > 0) --impl.inFlight;
        impl.changed.notify_all();
    };
    const auto failWith = [&](std::string message) {
        undo();
        impl.fail(message);
        if (error != nullptr) *error = std::move(message);
        return SubmitResult::Failed;
    };

    @autoreleasepool {
        CMBlockBufferRef block = nullptr;
        OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, size, kCFAllocatorDefault,
                                                              nullptr, 0, size, kCMBlockBufferAssureMemoryNowFlag, &block);
        if (status != noErr || block == nullptr) return failWith("could not allocate a video sample (" + StatusText(status) + ")");
        status = CMBlockBufferReplaceDataBytes(data, block, 0, size);
        if (status != noErr) {
            CFRelease(block);
            return failWith("could not fill a video sample (" + StatusText(status) + ")");
        }

        CMSampleTimingInfo info {};
        info.duration              = CMTimeMake(timing.duration, impl.timescale);
        info.presentationTimeStamp = CMTimeMake(timing.pts, impl.timescale);
        info.decodeTimeStamp       = CMTimeMake(timing.dts, impl.timescale);
        CMSampleBufferRef sample   = nullptr;
        const std::size_t sampleSize = size;
        status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, static_cast<CMFormatDescriptionRef>(impl.format.description.get()),
                                           1, 1, &info, 1, &sampleSize, &sample);
        CFRelease(block);
        if (status != noErr || sample == nullptr) return failWith("could not wrap a video sample (" + StatusText(status) + ")");

        if (CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true)) {
            auto* dictionary = static_cast<CFMutableDictionaryRef>(const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
            CFDictionarySetValue(dictionary, kCMSampleAttachmentKey_NotSync, sync ? kCFBooleanFalse : kCFBooleanTrue);
        }

        VTDecodeInfoFlags infoFlags = 0;
        status = VTDecompressionSessionDecodeFrame(impl.session, sample, kVTDecodeFrame_EnableAsynchronousDecompression,
                                                   reinterpret_cast<void*>(PackRefCon(epoch, sequence)), &infoFlags);
        CFRelease(sample);
        if (status != noErr) {
            // The callback is not called for a frame the call itself refused.
            undo();
            std::lock_guard lock(impl.mutex);
            ++impl.skipped;
            if (status == kVTInvalidSessionErr || status == kVTVideoDecoderNotAvailableNowErr ||
                ++impl.consecutiveFailures >= kMaxConsecutiveFailures) {
                impl.failLocked("the video decoder refused a sample (" + StatusText(status) + ")");
                if (error != nullptr) *error = impl.failure;
                return SubmitResult::Failed;
            }
        }
    }
    return SubmitResult::Accepted;
}

VtFrameDecoder::ReceiveResult VtFrameDecoder::receive(DecodedFrame* out, std::chrono::milliseconds wait,
                                                      std::string* error)
{
    Impl& impl = *m_impl;
    std::unique_lock lock(impl.mutex);
    const auto deadline = std::chrono::steady_clock::now() + wait;
    while (true) {
        if (impl.failed) {
            if (error != nullptr) *error = impl.failure;
            return ReceiveResult::Failed;
        }
        if (! impl.ready.empty()) {
            const HeldFrame frame = impl.ready.front();
            impl.ready.pop_front();
            out->pixels = PixelBuffer(frame.buffer);
            out->pts    = frame.pts;
            impl.changed.notify_all();
            return ReceiveResult::Frame;
        }
        if (impl.draining && impl.inFlight == 0) {
            impl.releaseHeldLocked(true);
            if (impl.ready.empty()) return ReceiveResult::EndOfStream;
            continue;
        }
        if (impl.cancelled.load()) return ReceiveResult::NotReady;
        // Waiting only helps when the decoder still owes frames.
        if (impl.inFlight == 0 && ! impl.draining) return ReceiveResult::NotReady;
        if (impl.changed.wait_until(lock, deadline) == std::cv_status::timeout) {
            if (impl.ready.empty() && ! (impl.draining && impl.inFlight == 0)) return ReceiveResult::NotReady;
        }
    }
}

bool VtFrameDecoder::drain(std::string* error)
{
    Impl& impl = *m_impl;
    {
        std::lock_guard lock(impl.mutex);
        if (impl.failed) {
            if (error != nullptr) *error = impl.failure;
            return false;
        }
        impl.draining = true;
    }
    OSStatus status = VTDecompressionSessionFinishDelayedFrames(impl.session);
    if (status == noErr) status = VTDecompressionSessionWaitForAsynchronousFrames(impl.session);
    std::lock_guard lock(impl.mutex);
    impl.changed.notify_all();
    if (status != noErr && ! impl.cancelled.load()) {
        impl.failLocked("the video decoder could not finish its frames (" + StatusText(status) + ")");
        if (error != nullptr) *error = impl.failure;
        return false;
    }
    return true;
}

bool VtFrameDecoder::reset(std::string* error)
{
    Impl& impl = *m_impl;
    {
        std::lock_guard lock(impl.mutex);
        if (impl.failed) {
            if (error != nullptr) *error = impl.failure;
            return false;
        }
        // Frames already decoded, and frames the decoder is still working on, belong to the past.
        ++impl.epoch;
        impl.dropAllLocked();
        impl.draining            = false;
        impl.consecutiveFailures = 0;
    }
    // Waiting for what is in flight also empties the decoder's own reorder state,
    // so nothing from before can sit in front of the next epoch's first frame.
    OSStatus status = VTDecompressionSessionFinishDelayedFrames(impl.session);
    if (status == noErr) status = VTDecompressionSessionWaitForAsynchronousFrames(impl.session);
    std::lock_guard lock(impl.mutex);
    // Whatever arrived for the old epoch during the wait was dropped by the callback.
    impl.dropAllLocked();
    impl.changed.notify_all();
    if (status != noErr && ! impl.cancelled.load()) {
        impl.failLocked("the video decoder could not be reset (" + StatusText(status) + ")");
        if (error != nullptr) *error = impl.failure;
        return false;
    }
    return true;
}

void VtFrameDecoder::cancel()
{
    Impl& impl = *m_impl;
    impl.cancelled.store(true);
    std::lock_guard lock(impl.mutex);
    impl.changed.notify_all();
}

std::uint32_t VtFrameDecoder::pixelFormat() const { return m_impl->format.pixelFormat; }

bool VtFrameDecoder::usingHardware() const { return m_impl->hardware; }

std::uint64_t VtFrameDecoder::skippedFrames() const
{
    std::lock_guard lock(m_impl->mutex);
    return m_impl->skipped;
}

std::uint64_t VtFrameDecoder::outOfOrderCompletions() const
{
    std::lock_guard lock(m_impl->mutex);
    return m_impl->outOfOrder;
}

} // namespace wallpaper::media::apple
