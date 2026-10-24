#include "Video/NativeVideoBackend.hpp"

#include "Image.hpp"
#include "Media/Apple/FormatDescription.hpp"
#include "Media/Apple/VtFrameDecoder.hpp"
#include "Media/ByteSource.hpp"
#include "Media/DisplayMatrix.hpp"
#include "Media/IsoBmff/IsoBmffReader.hpp"
#include "Media/Matroska/MatroskaReader.hpp"
#include "Media/SampleOrder.hpp"
#include "Platform/Apple/VideoFrameInterop.hpp"
#include "Utils/Logging.h"
#include "Video/VideoContainerProbe.hpp"
#include "Video/VideoDecodePump.hpp"
#include "Video/VideoDisplayTransform.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <optional>
#include <utility>
#include <vector>

namespace wallpaper::video
{
namespace
{

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

/// How long a receive waits for the decoder when the decoder is full or draining.
/// A step that waits this long and gets nothing counts against the pump's
/// no-progress budget, so a decoder that produces nothing for
/// `kReceiveWait * 256` (about 13 s) fails the stream instead of spinning.
constexpr auto kReceiveWait = std::chrono::milliseconds(50);

bool StartsWithEbml(const media::ByteSource& source)
{
    std::uint8_t header[4] {};
    return media::ReadExact(source, 0, header, sizeof(header)) && header[0] == 0x1A && header[1] == 0x45 &&
           header[2] == 0xDF && header[3] == 0xA3;
}

} // namespace

uint64_t NativeVideoPayloadSpillBytes()
{
    constexpr uint64_t kDefault = 8ULL << 20;
    const char*        text     = std::getenv("WALLPAPER_MACHINE_VIDEO_SPILL_BYTES");
    if (text == nullptr || *text == '\0') return kDefault;
    char*      end   = nullptr;
    const auto value = std::strtoull(text, &end, 10);
    return end != text && *end == '\0' ? static_cast<uint64_t>(value) : kDefault;
}

class NativeVideoBackend::Impl {
public:
    explicit Impl(std::shared_ptr<const Image> image) : m_decode_source(*this), m_pump(m_decode_source)
    {
        if (image == nullptr) {
            m_initial_error = "video texture has no image";
            return;
        }
        m_label = image->key;
        if (!image->header.isVideo) {
            m_initial_error = "image is not marked as a video texture";
            return;
        }
        if (!image->videoFilePath.empty()) {
            m_path = image->videoFilePath;
            return;
        }
        if (image->slots.empty() || image->slots.front().mipmaps.empty()) {
            m_initial_error = "video texture has no mip payload";
            return;
        }
        const auto& mip = image->slots.front().mipmaps.front();
        if (mip.data == nullptr || mip.size <= 0) {
            m_initial_error = "video texture payload is empty";
            return;
        }
        // The bytes stay where the parser put them until the backend opens.
        m_image = std::move(image);
    }

    explicit Impl(std::string media_path)
        : m_label(media_path), m_path(std::move(media_path)), m_decode_source(*this), m_pump(m_decode_source)
    {
        if (m_path.empty()) m_initial_error = "video media path must not be empty";
    }

    ~Impl() { close(); }

    bool open(std::string* error)
    {
        if (!m_initial_error.empty()) return SetError(error, m_initial_error);
        if (m_cancelled.load()) return SetError(error, "video decoding was cancelled");

        std::string why;
        if (!resolveSource(&why)) return SetError(error, why);
        if (!openReader(&why)) return SetError(error, why);
        if (m_cancelled.load()) return SetError(error, "video decoding was cancelled");

        const media::VideoStreamInfo& info = *m_info;
        uint32_t                      width = 0, height = 0;
        if (!DisplaySizeOf(info, &width, &height)) {
            return SetError(error, "video display transform is not a valid affine transform");
        }
        if (info.timescale <= 0) return SetError(error, "the video has no usable time scale");
        m_timescale = static_cast<double>(info.timescale);

        const auto& samples = *m_samples;
        m_first_sync        = samples.size();
        for (std::size_t index = 0; index < samples.size(); ++index) {
            if (samples[index].sync) {
                m_first_sync = index;
                break;
            }
        }
        if (m_first_sync == samples.size()) return SetError(error, "the video has no key frame");

        std::vector<std::uint8_t> first;
        media::Error              read_error;
        if (!readSample(m_first_sync, &first, &read_error)) {
            return SetError(error, "failed to read the first video sample: " + media::Describe(read_error));
        }

        media::apple::StreamFormat format;
        if (!media::apple::MakeStreamFormat(info, m_vp9 ? &*m_vp9 : nullptr, first.data(), first.size(), &format, &why)) {
            // A format this Mac cannot decode says which in the reason.
            return SetError(error, why);
        }
        const std::size_t reorder = media::ReorderDepth(samples);
        auto decoder = media::apple::VtFrameDecoder::Create(std::move(format), info.timescale, reorder, {}, &why);
        if (decoder == nullptr) return SetError(error, why);
        m_decoder_raw.store(decoder.get());
        m_decoder = std::move(decoder);
        if (m_cancelled.load()) return SetError(error, "video decoding was cancelled");

        m_stream_info.duration_seconds =
            info.durationTicks > 0 ? static_cast<double>(info.durationTicks) / m_timescale : 0.0;
        m_stream_info.frame_duration_seconds =
            info.avgFramePeriod.valid() && info.avgFramePeriod.toDouble() > 0.0 ? info.avgFramePeriod.toDouble() : 1.0 / 60.0;
        m_stream_info.shortest_declared_period_seconds =
            info.minFramePeriod.valid() ? info.minFramePeriod.toDouble() : 0.0;
        m_cursor = m_first_sync;
        LOG_INFO("native video \"%s\": %s %ux%u, %zu samples, reorder depth %zu, %s decoder", m_label.c_str(),
                 media::FourCCString(info.codecFourcc).c_str(), width, height, samples.size(), reorder,
                 m_decoder->usingHardware() ? "hardware" : "software");
        // Last, because it replaces the reader `info` and `samples` above refer to.
        spillLargePayload();
        return true;
    }

    [[nodiscard]] VideoFrameBackend::StreamInfo streamInfo() const { return m_stream_info; }

    VideoFrameBackend::Decode decodeNext(DecodedPosition* position, std::string* error)
    {
        while (true) {
            switch (m_pump.NextFrame(error)) {
            case VideoDecodePump::Outcome::Cancelled:
                return VideoFrameBackend::Decode::Cancelled;
            case VideoDecodePump::Outcome::Failed:
                return VideoFrameBackend::Decode::Failed;
            case VideoDecodePump::Outcome::Frame:
                break;
            }
            // A frame before the start of the edit is decoded to feed the ones after
            // it and never shown; so is a leading picture of a random access point,
            // which refers to pictures that were never decoded.
            if (m_frame.pts < 0 || m_frame.pts < m_drop_before_pts) {
                m_frame = {};
                continue;
            }
            position->pts_seconds = static_cast<double>(m_frame.pts) / m_timescale;
            position->loop_index  = m_pump.loopIndex();
            return VideoFrameBackend::Decode::Frame;
        }
    }

    bool takeFrame(VideoTextureFrame* out, std::string* error)
    {
        VideoTextureFrame frame {};
        if (!AdoptPixelBufferAsVideoFrame(m_frame.pixels.release(), &frame, error)) return false;
        m_frame = {};
        if (m_info->displayMatrix != media::kIdentityDisplayMatrix) {
            const auto transform = ResolveVideoDisplayTransform(m_info->displayMatrix, frame.width, frame.height);
            if (!transform) {
                ReleaseAppleVideoFrame(&frame);
                return SetError(error, "video display transform is not a valid affine transform");
            }
            frame.display_transform = *transform;
        }
        *out = frame;
        return true;
    }

    void discardFrame() { m_frame = {}; }

    bool seek(double wrapped_seconds, uint64_t loop_index, std::string* error)
    {
        if (m_decoder == nullptr) return SetError(error, "the video decoder is not initialized");
        const auto ticks = static_cast<std::int64_t>(std::llround(wrapped_seconds * m_timescale));
        const std::optional<std::size_t> keyframe = m_iso ? m_iso->findKeyframeAtOrBefore(ticks)
                                                          : m_mkv->findVideoKeyframeAtOrBefore(ticks);
        if (!keyframe) return SetError(error, "the video has no key frame to seek to");
        if (!m_decoder->reset(error)) return false;
        m_frame = {};
        m_cursor = *keyframe;
        m_decoder_full = false;
        m_draining = false;
        m_drop_before_pts = (*m_samples)[*keyframe].pts;
        m_pump.ResetForSeek();
        m_pump.setLoopIndex(loop_index);
        return true;
    }

    [[nodiscard]] uint64_t loopIndex() const { return m_pump.loopIndex(); }

    void cancel()
    {
        m_cancelled.store(true);
        if (auto* decoder = m_decoder_raw.load()) decoder->cancel();
    }

    void close()
    {
        m_decoder_raw.store(nullptr);
        m_frame = {};
        m_decoder.reset();
        m_iso.reset();
        m_mkv.reset();
        m_source.reset();
        m_image.reset();
    }

private:
    /// The pump's view of the decoder: samples in, frames out, restart at the head.
    class DecodeSource final : public VideoDecodeSource {
    public:
        explicit DecodeSource(Impl& owner) : m_owner(owner) {}

        DecodeStatus ReadPacket(std::string* error) override
        {
            if (m_owner.m_cancelled.load()) return DecodeStatus::Again;
            if (m_owner.m_cursor >= m_owner.m_samples->size()) return DecodeStatus::EndOfStream;
            media::Error read_error;
            if (!m_owner.readSample(m_owner.m_cursor, &m_owner.m_packet, &read_error)) {
                SetError(error, "failed to read a video sample: " + media::Describe(read_error));
                return DecodeStatus::Error;
            }
            m_owner.m_held_index = m_owner.m_cursor++;
            return DecodeStatus::Ok;
        }

        DecodeStatus SendPacket(std::string* error) override
        {
            const media::Sample& sample = (*m_owner.m_samples)[m_owner.m_held_index];
            switch (m_owner.m_decoder->submit(m_owner.m_packet.data(), m_owner.m_packet.size(),
                                              { sample.pts, sample.dts, sample.duration }, sample.sync, error)) {
            case media::apple::VtFrameDecoder::SubmitResult::Accepted:
                m_owner.m_decoder_full = false;
                return DecodeStatus::Ok;
            case media::apple::VtFrameDecoder::SubmitResult::Full:
                // The next receive has to wait for the decoder, not spin.
                m_owner.m_decoder_full = true;
                return DecodeStatus::Again;
            case media::apple::VtFrameDecoder::SubmitResult::Failed:
                break;
            }
            if (m_owner.m_cancelled.load()) return DecodeStatus::Again;
            if (error != nullptr && error->empty()) *error = "the video decoder refused a sample";
            return DecodeStatus::Error;
        }

        void ReleasePacket() override {}

        DecodeStatus SendDrainRequest(std::string* error) override
        {
            m_owner.m_draining = true;
            if (m_owner.m_decoder->drain(error)) return DecodeStatus::Ok;
            if (m_owner.m_cancelled.load()) return DecodeStatus::Ok;
            return DecodeStatus::Error;
        }

        DecodeStatus ReceiveFrame(std::string* error) override
        {
            // Wait only when there is nothing else to do: the decoder is full, or the
            // input has ended. Otherwise an empty receive returns at once and the pump
            // feeds the decoder, which keeps it busy instead of lock-stepped.
            const auto wait = (m_owner.m_decoder_full || m_owner.m_draining) ? kReceiveWait
                                                                             : std::chrono::milliseconds(0);
            switch (m_owner.m_decoder->receive(&m_owner.m_frame, wait, error)) {
            case media::apple::VtFrameDecoder::ReceiveResult::Frame:
                m_owner.m_decoder_full = false;
                return DecodeStatus::Ok;
            case media::apple::VtFrameDecoder::ReceiveResult::NotReady:
                return DecodeStatus::Again;
            case media::apple::VtFrameDecoder::ReceiveResult::EndOfStream:
                return DecodeStatus::EndOfStream;
            case media::apple::VtFrameDecoder::ReceiveResult::Failed:
                break;
            }
            return DecodeStatus::Error;
        }

        bool RestartAtStreamStart(std::string* error) override
        {
            if (!m_owner.m_decoder->reset(error)) return false;
            m_owner.m_cursor          = m_owner.m_first_sync;
            m_owner.m_decoder_full    = false;
            m_owner.m_draining        = false;
            m_owner.m_drop_before_pts = std::numeric_limits<std::int64_t>::min();
            return true;
        }

        [[nodiscard]] bool IsCancelled() const override { return m_owner.m_cancelled.load(); }

    private:
        Impl& m_owner;
    };

    /// Finds where the bytes are: a file in place, or the payload in memory,
    /// shared with the image it came in.
    bool resolveSource(std::string* why)
    {
        if (m_source != nullptr) return true;
        media::Error error;
        if (!m_path.empty()) {
            m_source = media::OpenFileByteSource(m_path, &error);
            if (m_source == nullptr) {
                return SetError(why, "failed to open video file: " + media::Describe(error));
            }
            return true;
        }
        if (m_image == nullptr) return SetError(why, "video texture payload is empty");
        const auto& mip = m_image->slots.front().mipmaps.front();
        // The source shares the image, which is how a payload stays valid after the scene lets go of it.
        m_source = media::MakeMemoryByteSource(std::shared_ptr<const void>(m_image),
                                               reinterpret_cast<const std::uint8_t*>(mip.data.get()),
                                               static_cast<std::size_t>(mip.size));
        return true;
    }

    /// Once the stream is known to play, moves a large embedded payload out of the
    /// process: the readers are opened again on an anonymous file holding a copy,
    /// and the image's buffer is let go, so a long video does not stay resident for
    /// as long as it plays. Any failure leaves the payload where it was.
    void spillLargePayload()
    {
        if (m_image == nullptr || m_source == nullptr) return;
        const auto&       mip   = m_image->slots.front().mipmaps.front();
        const std::size_t size  = static_cast<std::size_t>(mip.size);
        if (static_cast<uint64_t>(size) <= NativeVideoPayloadSpillBytes()) return;

        media::Error error;
        auto spilled = media::MakeSpilledByteSource(reinterpret_cast<const std::uint8_t*>(mip.data.get()), size, &error);
        if (spilled == nullptr) {
            LOG_ERROR("native video \"%s\": could not move the payload out of memory (%s); keeping it resident",
                      m_label.c_str(), media::Describe(error).c_str());
            return;
        }
        if (m_iso != nullptr) {
            auto reopened = media::IsoBmffReader::Open(spilled, &error);
            if (reopened == nullptr) {
                LOG_ERROR("native video \"%s\": the copy of the payload did not read back (%s); keeping it resident",
                          m_label.c_str(), media::Describe(error).c_str());
                return;
            }
            m_iso     = std::move(reopened);
            m_info    = &m_iso->info();
            m_samples = &m_iso->samples();
        } else {
            auto reopened = media::MatroskaReader::Open(spilled, &error);
            if (reopened == nullptr) {
                LOG_ERROR("native video \"%s\": the copy of the payload did not read back (%s); keeping it resident",
                          m_label.c_str(), media::Describe(error).c_str());
                return;
            }
            m_mkv     = std::move(reopened);
            m_info    = &m_mkv->videoInfo();
            m_samples = &m_mkv->videoSamples();
            m_vp9.reset();
            if (m_mkv->vp9KeyFrame()) m_vp9 = *m_mkv->vp9KeyFrame();
        }
        m_source = std::move(spilled);
        m_image.reset();
    }

    bool openReader(std::string* why)
    {
        media::Error error;
        if (media::LooksLikeIsoBmff(*m_source)) {
            m_iso = media::IsoBmffReader::Open(m_source, &error);
            if (m_iso == nullptr) {
                return SetError(why, "failed to read the MP4 file: " + media::Describe(error));
            }
            m_info    = &m_iso->info();
            m_samples = &m_iso->samples();
            return true;
        }
        if (StartsWithEbml(*m_source)) {
            m_mkv = media::MatroskaReader::Open(m_source, &error);
            if (m_mkv == nullptr) {
                // A codec this project does not play (VP8) says so in the reader's own words.
                std::string reason = media::Describe(error);
                if (error.kind == media::ErrorKind::Unsupported) {
                    return SetError(why, std::string(media::apple::kFormatNotSupported) + reason);
                }
                return SetError(why, "failed to read the WebM file: " + reason);
            }
            m_info    = &m_mkv->videoInfo();
            m_samples = &m_mkv->videoSamples();
            if (m_mkv->vp9KeyFrame()) m_vp9 = *m_mkv->vp9KeyFrame();
            return true;
        }
        return SetError(why, std::string(media::apple::kFormatNotSupported) +
                                 "the container is not MP4, QuickTime, WebM or Matroska");
    }

    bool readSample(std::size_t index, std::vector<std::uint8_t>* out, media::Error* error) const
    {
        return m_iso ? m_iso->readSample(index, out, error) : m_mkv->readSample(index, out, error);
    }

    std::string                          m_label;
    std::string                          m_initial_error;
    std::shared_ptr<const Image>         m_image;
    std::string                          m_path;
    std::shared_ptr<media::ByteSource>   m_source;
    std::unique_ptr<media::IsoBmffReader>  m_iso;
    std::unique_ptr<media::MatroskaReader> m_mkv;
    const media::VideoStreamInfo*        m_info { nullptr };
    const std::vector<media::Sample>*    m_samples { nullptr };
    std::optional<media::Vp9FrameHeader> m_vp9;
    double                               m_timescale { 1.0 };
    std::size_t                          m_first_sync { 0 };
    VideoFrameBackend::StreamInfo        m_stream_info;
    std::unique_ptr<media::apple::VtFrameDecoder> m_decoder;
    /// For `cancel`, which any thread may call while the decoder is being set up.
    std::atomic<media::apple::VtFrameDecoder*> m_decoder_raw { nullptr };
    std::atomic<bool>                    m_cancelled { false };

    // Decode-thread state.
    std::size_t                          m_cursor { 0 };
    std::size_t                          m_held_index { 0 };
    std::vector<std::uint8_t>            m_packet;
    bool                                 m_decoder_full { false };
    bool                                 m_draining { false };
    media::apple::DecodedFrame           m_frame;
    std::int64_t                         m_drop_before_pts { std::numeric_limits<std::int64_t>::min() };

    /// Declared last so everything they borrow is initialized first.
    DecodeSource                         m_decode_source;
    VideoDecodePump                      m_pump;
};

NativeVideoBackend::NativeVideoBackend(std::shared_ptr<const Image> image)
    : m_impl(std::make_unique<Impl>(std::move(image)))
{
}

NativeVideoBackend::NativeVideoBackend(std::string media_path)
    : m_impl(std::make_unique<Impl>(std::move(media_path)))
{
}

NativeVideoBackend::~NativeVideoBackend() = default;

bool NativeVideoBackend::open(std::string* error) { return m_impl->open(error); }

VideoFrameBackend::StreamInfo NativeVideoBackend::streamInfo() const { return m_impl->streamInfo(); }

VideoFrameBackend::Decode NativeVideoBackend::decodeNext(double, DecodedPosition* position, std::string* error)
{
    return m_impl->decodeNext(position, error);
}

bool NativeVideoBackend::takeFrame(VideoTextureFrame* out, std::string* error)
{
    return m_impl->takeFrame(out, error);
}

void NativeVideoBackend::discardFrame() { m_impl->discardFrame(); }

bool NativeVideoBackend::seek(double wrapped_seconds, uint64_t loop_index, std::string* error)
{
    return m_impl->seek(wrapped_seconds, loop_index, error);
}

uint64_t NativeVideoBackend::loopIndex() const { return m_impl->loopIndex(); }

void NativeVideoBackend::cancel() { m_impl->cancel(); }

void NativeVideoBackend::close() { m_impl->close(); }

} // namespace wallpaper::video
