#include "Video/FfmpegVideoTextureSource.hpp"

#include "Image.hpp"
#include "Video/FfmpegAbi.hpp"
#include "Video/VideoDecodePump.hpp"
#include "Video/VideoFramePacing.hpp"
#include "Video/VideoMetadata.hpp"
#include "Video/VideoSeekPolicy.hpp"
#include "Platform/Apple/FfmpegVideoInterop.hpp"
#include "Utils/Logging.h"
#include "Utils/Sha.hpp"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/codec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libavutil/pixfmt.h>
}

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <optional>
#include <deque>
#include <exception>
#include <filesystem>
#include <fstream>
#include <limits>
#include <mutex>
#include <span>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

namespace wallpaper::video
{
namespace
{

constexpr auto kPrimeTimeout = std::chrono::seconds(2);
constexpr auto kDecodePoll = std::chrono::milliseconds(2);

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

std::string AvErrorString(int error_code)
{
    std::array<char, AV_ERROR_MAX_STRING_SIZE> buffer {};
    av_strerror(error_code, buffer.data(), buffer.size());
    return std::string(buffer.data());
}

double WrapSeconds(double seconds, double duration_seconds)
{
    if (!(duration_seconds > 0.0) || !std::isfinite(seconds)) return 0.0;
    double wrapped = std::fmod(seconds, duration_seconds);
    if (wrapped < 0.0) wrapped += duration_seconds;
    if (wrapped >= duration_seconds) wrapped = 0.0;
    return wrapped;
}

double CircularDistance(double left, double right, double duration_seconds)
{
    if (!(duration_seconds > 0.0)) return std::abs(left - right);
    const double direct = std::abs(left - right);
    return std::min(direct, duration_seconds - direct);
}

std::filesystem::path VideoCacheDirectory(std::string* error)
{
    std::filesystem::path temp_dir = std::filesystem::temp_directory_path() / "wallpaper-engine-video";
    std::error_code       ec;
    std::filesystem::create_directories(temp_dir, ec);
    if (ec) {
        SetError(error, "failed to create temporary video cache directory");
        return {};
    }
    return temp_dir;
}

/// Extracts an inline video payload into the shared cache so FFmpeg can open
/// it by path.
///
/// The bytes are staged under a name unique to this attempt and only then
/// renamed onto the content-addressed name, so a concurrent opener either sees
/// nothing or sees the finished file - never a half-written one. Losing the
/// rename race is success: the winner's file holds the same bytes.
std::filesystem::path WriteVideoPayloadToTemp(std::string_view debug_label,
                                              const std::vector<char>& payload,
                                              std::string* error)
{
    if (payload.empty()) {
        SetError(error, "video texture payload is empty");
        return {};
    }

    const std::filesystem::path temp_dir = VideoCacheDirectory(error);
    if (temp_dir.empty()) return {};

    std::error_code ec;
    const std::string digest = utils::genSha1(std::span(payload.data(), payload.size()));
    const std::filesystem::path media_path = temp_dir / (digest + ".mp4");
    const auto payload_size = static_cast<uintmax_t>(payload.size());
    if (std::filesystem::exists(media_path, ec) &&
        !ec &&
        std::filesystem::file_size(media_path, ec) == payload_size) {
        return media_path;
    }

    static std::atomic<uint64_t> staging_serial { 0 };
    const std::filesystem::path staging_path =
        temp_dir / (digest + "." + std::to_string(static_cast<long long>(getpid())) + "." +
                    std::to_string(staging_serial.fetch_add(1, std::memory_order_relaxed)) + ".part");
    std::ofstream output(staging_path, std::ios::binary | std::ios::trunc);
    if (!output.good()) {
        SetError(error, "failed to open temporary video cache file");
        return {};
    }

    output.write(payload.data(), static_cast<std::streamsize>(payload.size()));
    output.close();
    // The size on disk is the completion check: a short write is discarded
    // instead of reaching the published name.
    if (!output.good() || std::filesystem::file_size(staging_path, ec) != payload_size || ec) {
        std::filesystem::remove(staging_path, ec);
        SetError(error, "failed to write temporary video cache file");
        return {};
    }

    std::filesystem::rename(staging_path, media_path, ec);
    if (ec) {
        std::error_code remove_ec;
        std::filesystem::remove(staging_path, remove_ec);
        if (std::filesystem::file_size(media_path, ec) == payload_size && !ec) return media_path;
        SetError(error, "failed to write temporary video cache file");
        return {};
    }

    LOG_INFO("prepared FFmpeg video payload cache for \"%s\": %s",
             std::string(debug_label).c_str(),
             media_path.string().c_str());
    return media_path;
}

/// Identity of a running decoder instance. Monotonic and never reused, so a
/// report can de-duplicate one source's work across several consumers without
/// ever merging two decoders that happen to read the same file.
uint64_t NextVideoSourceInstanceId()
{
    static std::atomic<uint64_t> next { 1 };
    return next.fetch_add(1, std::memory_order_relaxed);
}

double ProbeDurationSeconds(AVFormatContext* format_context, AVStream* stream)
{
    if (stream != nullptr && stream->duration > 0) {
        const double stream_duration = stream->duration * av_q2d(stream->time_base);
        if (std::isfinite(stream_duration) && stream_duration > 0.0) return stream_duration;
    }
    if (format_context != nullptr && format_context->duration > 0) {
        const double format_duration =
            static_cast<double>(format_context->duration) / static_cast<double>(AV_TIME_BASE);
        if (std::isfinite(format_duration) && format_duration > 0.0) return format_duration;
    }
    return 0.0;
}

/// Shortest period the container's declared rates imply.
///
/// `avg_frame_rate` is an average and `r_frame_rate` is libavformat's estimate,
/// so neither proves how far apart two particular frames are. This value is
/// only ever combined with observed presentation timestamps, never trusted on
/// its own to decide that a frame can be skipped.
double ProbeShortestFrameDurationSeconds(AVStream* stream)
{
    if (stream == nullptr) return 0.0;
    const std::array<video::FrameRateRatio, 2> rates {
        video::FrameRateRatio { stream->avg_frame_rate.num, stream->avg_frame_rate.den },
        video::FrameRateRatio { stream->r_frame_rate.num, stream->r_frame_rate.den },
    };
    return video::ShortestMetadataPeriodSeconds(rates.data(), rates.size());
}

double ProbeFrameDurationSeconds(AVStream* stream)
{
    if (stream == nullptr) return 1.0 / 60.0;
    const AVRational frame_rate = stream->avg_frame_rate.num != 0 && stream->avg_frame_rate.den != 0
        ? stream->avg_frame_rate
        : stream->r_frame_rate;
    if (frame_rate.num > 0 && frame_rate.den > 0) {
        const double fps = av_q2d(frame_rate);
        if (std::isfinite(fps) && fps > 0.0) return 1.0 / fps;
    }
    return 1.0 / 60.0;
}

std::optional<std::array<int32_t, 9>> StreamDisplayMatrix(const AVStream* stream) {
    if (stream == nullptr || stream->codecpar == nullptr) return std::nullopt;
    const auto* side = av_packet_side_data_get(stream->codecpar->coded_side_data,
        stream->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (side == nullptr || side->data == nullptr || side->size < 9 * sizeof(int32_t)) return std::nullopt;
    std::array<int32_t, 9> matrix;
    std::memcpy(matrix.data(), side->data, sizeof(matrix));
    return matrix;
}

bool ProbeStreamDimensions(AVStream* stream, uint32_t* width, uint32_t* height, std::string* error)
{
    if (stream == nullptr) return SetError(error, "FFmpeg video stream must not be null");
    if (width == nullptr) return SetError(error, "video width output must not be null");
    if (height == nullptr) return SetError(error, "video height output must not be null");
    if (stream->codecpar == nullptr) return SetError(error, "FFmpeg video stream has no codec parameters");

    uint32_t resolved_width = static_cast<uint32_t>(std::max(0, stream->codecpar->width));
    uint32_t resolved_height = static_cast<uint32_t>(std::max(0, stream->codecpar->height));
    if (resolved_width == 0 || resolved_height == 0) {
        return SetError(error, "FFmpeg video stream returned an invalid size");
    }

    if (const auto matrix = StreamDisplayMatrix(stream)) {
        const auto transform = ResolveVideoDisplayTransform(*matrix, resolved_width, resolved_height);
        if (! transform) return SetError(error, "video display transform is not a valid affine transform");
        resolved_width = transform->width;
        resolved_height = transform->height;
    }

    *width = resolved_width;
    *height = resolved_height;
    return true;
}

#if defined(__APPLE__)
AVPixelFormat AppleHardwarePixelFormat(const AVCodec* codec)
{
    for (int index = 0;; ++index) {
        const AVCodecHWConfig* config = avcodec_get_hw_config(codec, index);
        if (config == nullptr) return AV_PIX_FMT_NONE;
        if ((config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 &&
            config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX) {
            return config->pix_fmt;
        }
    }
}

const AVCodec* SelectAppleHardwareDecoder(const AVCodec* preferred, AVPixelFormat* pixel_format)
{
    *pixel_format = AppleHardwarePixelFormat(preferred);
    if (*pixel_format != AV_PIX_FMT_NONE) return preferred;

    // FFmpeg's default can be software-only even when another decoder for the
    // same codec supports VideoToolbox (libdav1d versus native AV1, for example).
    // Search only at open, and keep the same hardware capability requirement.
    void* iterator = nullptr;
    while (const AVCodec* candidate = av_codec_iterate(&iterator)) {
        if (candidate->id != preferred->id || !av_codec_is_decoder(candidate)) continue;
        const auto format = AppleHardwarePixelFormat(candidate);
        if (format == AV_PIX_FMT_NONE) continue;
        *pixel_format = format;
        return candidate;
    }
    return nullptr;
}

AVPixelFormat SelectAppleHardwareFormat(AVCodecContext* context, const AVPixelFormat* formats)
{
    if (context == nullptr || formats == nullptr) return AV_PIX_FMT_NONE;

    const AVPixelFormat desired_format =
        context->opaque != nullptr
        ? *reinterpret_cast<const AVPixelFormat*>(context->opaque)
        : AV_PIX_FMT_NONE;
    for (auto* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
        if (*format == desired_format) {
            return *format;
        }
    }

    for (auto* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
        const auto* descriptor = av_pix_fmt_desc_get(*format);
        if (descriptor != nullptr &&
            (descriptor->flags & AV_PIX_FMT_FLAG_HWACCEL) == 0) {
            return *format;
        }
    }

    return formats[0];
}
#endif

double FramePtsSeconds(const AVFrame* frame, AVRational time_base, double fallback_seconds)
{
    if (frame == nullptr) return fallback_seconds;
    if (frame->best_effort_timestamp != AV_NOPTS_VALUE) {
        const double seconds = frame->best_effort_timestamp * av_q2d(time_base);
        if (std::isfinite(seconds) && seconds >= 0.0) return seconds;
    }
    if (frame->pts != AV_NOPTS_VALUE) {
        const double seconds = frame->pts * av_q2d(time_base);
        if (std::isfinite(seconds) && seconds >= 0.0) return seconds;
    }
    return fallback_seconds;
}

} // namespace

class FfmpegVideoTextureSource::Impl {
public:
    /// Opens the decoder on a media file directly. The path has already been
    /// resolved and validated by whoever opened the first decoder on it.
    explicit Impl(std::string media_path)
        : m_debug_label(media_path), m_media_path(std::move(media_path))
    {
        if (m_media_path.empty()) {
            m_initial_error = "video media path must not be empty";
        }
    }

    explicit Impl(const Image& image)
        : m_debug_label(image.key)
    {
        if (!image.header.isVideo) {
            m_initial_error = "image is not marked as a video texture";
            return;
        }
        if (!image.videoFilePath.empty()) {
            // The media already is a file: the decoder opens it where it lies,
            // so this source never holds the video's bytes at all.
            m_media_path = image.videoFilePath;
            return;
        }
        if (image.slots.empty() || image.slots.front().mipmaps.empty()) {
            m_initial_error = "video texture has no mip payload";
            return;
        }

        const auto& mip = image.slots.front().mipmaps.front();
        if (mip.data == nullptr || mip.size <= 0) {
            m_initial_error = "video texture payload is empty";
            return;
        }

        m_payload.assign(
            reinterpret_cast<const char*>(mip.data.get()),
            reinterpret_cast<const char*>(mip.data.get()) + static_cast<size_t>(mip.size));
    }

    ~Impl()
    {
        stop();
        clearFrames();
        closeDecoder();
    }

    bool prime(std::string* error)
    {
        // Every consumer waits for the same complete attempt, including its
        // failure. Decoder handles and the worker thread have one initializer.
        std::call_once(m_prime_once, [this] {
            try {
                m_prime_succeeded = primeOnce(&m_prime_error);
            } catch (const std::exception& exception) {
                m_prime_error = std::string("failed to initialize FFmpeg video: ") + exception.what();
            }
            if (! m_prime_succeeded) {
                stop();
                clearFrames();
                closeDecoder();
            }
        });
        if (m_prime_succeeded) return true;
        return SetError(error, m_prime_error);
    }

private:
    bool primeOnce(std::string* error)
    {
        std::unique_lock lock(m_mutex);
        if (m_primed) return true;
        if (!m_initial_error.empty()) return SetError(error, m_initial_error);
        lock.unlock();

        std::string local_error;
        if (!openDecoder(&local_error)) {
            return SetError(error, std::move(local_error));
        }

        {
            std::lock_guard state_lock(m_mutex);
            m_scene_absolute_seconds = 0.0;
            m_clock_base_seconds = 0.0;
            m_clock_initialized = true;
            m_running = true;
            m_stop_requested = false;
        }

        m_decode_thread = std::thread([this]() { decodeLoop(); });

        lock.lock();
        const auto ready = m_condition.wait_for(
            lock,
            kPrimeTimeout,
            [this]() {
                return m_display_frame_ready || !m_last_error.empty();
            });
        if (!ready) {
            lock.unlock();
            stop();
            return SetError(error, "timed out waiting for the first FFmpeg video frame");
        }
        if (!m_last_error.empty()) {
            const std::string failure = m_last_error;
            lock.unlock();
            stop();
            return SetError(error, failure);
        }

        m_primed = true;
        return true;
    }

public:
    bool syncPlayback(const VideoPlaybackState& state, std::string* error)
    {
        if (state.rate < 0.0f) return SetError(error, "negative video playback rates are not supported");

        std::lock_guard lock(m_mutex);
        if (!m_last_error.empty()) return SetError(error, m_last_error);

        const auto now = std::chrono::steady_clock::now();
        const double requested_absolute_seconds = std::max(0.0, state.scene_elapsed_seconds);
        m_scene_absolute_seconds = requested_absolute_seconds;
        m_clock_base_seconds = WrapSeconds(requested_absolute_seconds, m_duration_seconds);
        m_clock_base_time = now;
        m_clock_initialized = true;
        m_playback_state = state;
        m_playback_state.rate = std::max(state.rate, 0.0f);
        const double discontinuity_threshold = std::max(0.5, m_frame_duration_seconds * 8.0);
        if (m_display_frame_ready &&
            requested_absolute_seconds + discontinuity_threshold < m_display_frame.absolute_seconds) {
            clearDisplayFrameLocked();
            requestSeekLocked(requested_absolute_seconds);
            // A seek, or a display slot that just went empty, is the only reason
            // the decode thread has new work. An ordinary clock update does not.
            m_condition.notify_all();
        }
        return true;
    }

    bool refreshFrame(std::string* error)
    {
        std::unique_lock lock(m_mutex);
        if (!m_last_error.empty() && !m_display_frame_ready) {
            return SetError(error, m_last_error);
        }

        const double desired_absolute_seconds = currentDesiredAbsoluteLocked();
        const double backward_threshold = std::max(0.05, m_frame_duration_seconds * 2.0);
        if (m_display_frame_ready &&
            desired_absolute_seconds + backward_threshold < m_display_frame.absolute_seconds) {
            clearDisplayFrameLocked();
            requestSeekLocked(desired_absolute_seconds);
        }

        const double forward_resync_threshold = ForwardResyncSeconds(
            m_frame_duration_seconds, static_cast<double>(kDecodedFrameQueueCapacity),
            m_seek_landing_lag_seconds);
        if (!seekInFlightCoversLocked(desired_absolute_seconds, backward_threshold,
                                      forward_resync_threshold) &&
            (!m_display_frame_ready ||
             desired_absolute_seconds > latestBufferedAbsoluteLocked() + forward_resync_threshold)) {
            requestSeekLocked(desired_absolute_seconds);
        }
        // A seek requested above, or a display frame just cleared, is work the
        // decode thread cannot see until it is woken. Promoting a queued frame
        // is the other one: it freed a slot the thread may be waiting on.
        if (m_seek_requested) m_condition.notify_all();

        bool promoted = false;
        while (!m_pending_frames.empty() &&
               (!m_display_frame_ready ||
                m_pending_frames.front().absolute_seconds <=
                    desired_absolute_seconds + presentationSlackSeconds())) {
            promoted = promoteNextFrameLocked() || promoted;
        }
        if (m_display_frame_ready) {
            // Promoting freed a queue slot. The display frame staying put did not.
            if (promoted || m_seek_requested) m_condition.notify_all();
            return true;
        }

        const auto deadline = std::chrono::steady_clock::now() + kPrimeTimeout;
        while (true) {
            while (!m_pending_frames.empty() &&
                   (!m_display_frame_ready ||
                    m_pending_frames.front().absolute_seconds <=
                        desired_absolute_seconds + presentationSlackSeconds())) {
                promoteNextFrameLocked();
            }

            if (m_display_frame_ready ||
                displayFrameCoversDesiredLocked(desired_absolute_seconds)) {
                return true;
            }

            if (!m_last_error.empty() && !m_display_frame_ready) {
                return SetError(error, m_last_error);
            }

            if (std::chrono::steady_clock::now() >= deadline) {
                if (m_display_frame_ready) {
                    return true;
                }
                return SetError(error, "video frame is not ready");
            }

            // Still waiting on a frame this thread does not have. Wake the
            // decoder only if a seek or an empty display slot is outstanding;
            // the poll below is what notices a frame arriving either way.
            if (m_seek_requested || !m_display_frame_ready) m_condition.notify_all();
            m_condition.wait_for(lock, kDecodePoll, [this]() {
                return m_stop_requested || !m_last_error.empty() || !m_pending_frames.empty();
            });
        }
    }

    [[nodiscard]] VideoTextureFrame currentFrame() const
    {
        std::lock_guard lock(m_mutex);
        if (!m_display_frame_ready) return {};
        return m_display_frame.frame;
    }

    [[nodiscard]] bool retainCurrentFrame(VideoTextureFrame* out) const
    {
        if (out == nullptr) return false;
        // Retaining inside the lock is the whole point: promotion releases the
        // previous display frame under this same lock, so a reader that has the
        // lock cannot have its frame freed underneath it.
        std::lock_guard lock(m_mutex);
        if (!m_display_frame_ready) return false;
        RetainAppleVideoFrame(m_display_frame.frame, out);
        return true;
    }

    [[nodiscard]] double durationSeconds() const
    {
        std::lock_guard lock(m_mutex);
        return m_duration_seconds;
    }

    [[nodiscard]] double playbackSeconds() const
    {
        std::lock_guard lock(m_mutex);
        return currentDesiredSecondsLocked();
    }

    [[nodiscard]] uint64_t loopCount() const
    {
        std::lock_guard lock(m_mutex);
        return m_loop_count;
    }

    [[nodiscard]] double frameDurationSeconds() const
    {
        std::lock_guard lock(m_mutex);
        // Zero until enough real presentation timestamps have been seen, which
        // the frame clock reads as "unknown" and answers with the fixed
        // cadence. Declared rates alone never unlock pacing.
        return m_primed ? m_pacing.PeriodSeconds() : 0.0;
    }

    [[nodiscard]] VideoSourceStats sourceStats() const
    {
        std::lock_guard lock(m_mutex);
        return VideoSourceStats {
            .instance_id = m_instance_id,
            .decoded_frames = m_decoded_frame_count,
            .seek_requests = m_seek_request_count,
            .observed_period_seconds = m_pacing.ObservedPeriodSeconds(),
            .observed_samples = m_pacing.SampleCount(),
        };
    }

private:
    static constexpr size_t kDecodedFrameQueueCapacity = 8;
    /// Packets of other streams consumed within one `ReadPacket` call before
    /// yielding, so a badly interleaved container cannot monopolize the step.
    static constexpr int kMaxForeignPacketsPerRead = 64;

    struct DecodedFrameSlot {
        VideoTextureFrame frame {};
        double            pts_seconds { 0.0 };
        double            absolute_seconds { 0.0 };
        uint64_t          loop_index { 0 };
        bool              ready { false };
    };

    enum class DecodeOutcome {
        Frame,
        /// `stop()` was requested. Not an error: no failure is recorded and the
        /// thread exits without surfacing a message to the user.
        Cancelled,
        Failed,
    };

    /// libavcodec-backed source for `VideoDecodePump`. It borrows the decoder
    /// objects owned by `Impl` and is only ever touched by the decode thread.
    class DecodeSource final : public VideoDecodeSource {
    public:
        explicit DecodeSource(Impl& owner) : m_owner(owner) {}

        DecodeStatus ReadPacket(std::string* error) override
        {
            for (int skipped = 0; skipped <= kMaxForeignPacketsPerRead; ++skipped) {
                const int result = av_read_frame(m_owner.m_format_context, m_owner.m_packet);
                if (result == AVERROR_EOF) return DecodeStatus::EndOfStream;
                if (result == AVERROR(EAGAIN)) return DecodeStatus::Again;
                if (result < 0) {
                    // An interrupted read is cancellation, not a stream defect.
                    if (m_owner.m_cancel_requested.load(std::memory_order_relaxed)) {
                        return DecodeStatus::Again;
                    }
                    SetError(error, "failed to read FFmpeg packet: " + AvErrorString(result));
                    return DecodeStatus::Error;
                }
                if (m_owner.m_packet->stream_index == m_owner.m_video_stream_index) {
                    return DecodeStatus::Ok;
                }
                av_packet_unref(m_owner.m_packet);
            }
            return DecodeStatus::Again;
        }

        DecodeStatus SendPacket(std::string* error) override
        {
            const int result = avcodec_send_packet(m_owner.m_codec_context, m_owner.m_packet);
            if (result == 0) return DecodeStatus::Ok;
            if (result == AVERROR(EAGAIN)) return DecodeStatus::Again;
            if (result == AVERROR_EOF) return DecodeStatus::EndOfStream;
            SetError(error,
                     "failed to submit FFmpeg packet to decoder: " + AvErrorString(result));
            return DecodeStatus::Error;
        }

        void ReleasePacket() override { av_packet_unref(m_owner.m_packet); }

        DecodeStatus SendDrainRequest(std::string* error) override
        {
            const int result = avcodec_send_packet(m_owner.m_codec_context, nullptr);
            // A decoder that is already draining reports EOF for a second null
            // packet; both mean draining is under way.
            if (result == 0 || result == AVERROR_EOF) return DecodeStatus::Ok;
            SetError(error, "failed to start FFmpeg decoder drain: " + AvErrorString(result));
            return DecodeStatus::Error;
        }

        DecodeStatus ReceiveFrame(std::string* error) override
        {
            const int result = avcodec_receive_frame(m_owner.m_codec_context, m_owner.m_frame);
            if (result == 0) return DecodeStatus::Ok;
            if (result == AVERROR(EAGAIN)) return DecodeStatus::Again;
            if (result == AVERROR_EOF) return DecodeStatus::EndOfStream;
            SetError(error,
                     "failed to receive FFmpeg decoded frame: " + AvErrorString(result));
            return DecodeStatus::Error;
        }

        bool RestartAtStreamStart(std::string* error) override
        {
            return m_owner.seekToSeconds(0.0, error);
        }

        [[nodiscard]] bool IsCancelled() const override
        {
            return m_owner.m_cancel_requested.load(std::memory_order_relaxed);
        }

    private:
        Impl& m_owner;
    };

    /// Aborts blocking libavformat I/O once cancellation is requested, so
    /// `stop()` does not wait on a stalled read before joining the thread.
    static int InterruptDecoder(void* opaque)
    {
        const auto* impl = static_cast<const Impl*>(opaque);
        return impl != nullptr && impl->m_cancel_requested.load(std::memory_order_relaxed) ? 1 : 0;
    }

    /// Makes the media openable by path.
    ///
    /// A file-backed source already has its path and keeps it. An inline
    /// payload is extracted once and then released, so the decoder does not go
    /// on holding a whole second copy of the video for the rest of playback.
    bool resolveMediaPath(std::string* error)
    {
        if (!m_media_path.empty()) return true;

        m_media_path = WriteVideoPayloadToTemp(m_debug_label, m_payload, error);
        if (m_media_path.empty()) return false;
        m_payload.clear();
        m_payload.shrink_to_fit();
        return true;
    }

    bool openDecoder(std::string* error)
    {
        if (auto mismatch = FfmpegAbiMismatch(); !mismatch.empty()) {
            return SetError(error, std::move(mismatch));
        }
        if (!resolveMediaPath(error)) return false;

        AVFormatContext* format_context = avformat_alloc_context();
        if (format_context == nullptr) {
            return SetError(error, "failed to allocate FFmpeg format context");
        }
        // Installed before opening so a stalled open is cancellable too.
        format_context->interrupt_callback.callback = &Impl::InterruptDecoder;
        format_context->interrupt_callback.opaque = this;
        if (const int result = avformat_open_input(&format_context, m_media_path.c_str(), nullptr, nullptr);
            result < 0) {
            return SetError(error, "failed to open FFmpeg input: " + AvErrorString(result));
        }

        if (const int result = avformat_find_stream_info(format_context, nullptr); result < 0) {
            avformat_close_input(&format_context);
            return SetError(error, "failed to read FFmpeg stream info: " + AvErrorString(result));
        }

        const int video_stream_index =
            av_find_best_stream(format_context, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
        if (video_stream_index < 0) {
            avformat_close_input(&format_context);
            return SetError(error, "failed to find FFmpeg video stream: " + AvErrorString(video_stream_index));
        }
        // Audio (and every other stream) is not decoded here. Discarding it
        // stops the demuxer from reading those packets at all; the video
        // stream, its PTS and the loop seam are unchanged.
        for (unsigned index = 0; index < format_context->nb_streams; ++index) {
            if (static_cast<int>(index) == video_stream_index) continue;
            if (format_context->streams[index] != nullptr) {
                format_context->streams[index]->discard = AVDISCARD_ALL;
            }
        }

        AVStream* video_stream = format_context->streams[video_stream_index];
        if (video_stream == nullptr || video_stream->codecpar == nullptr) {
            avformat_close_input(&format_context);
            return SetError(error, "FFmpeg video stream is missing codec parameters");
        }

        const AVCodec* codec = avcodec_find_decoder(video_stream->codecpar->codec_id);
        if (codec == nullptr) {
            avformat_close_input(&format_context);
            return SetError(error, "failed to find FFmpeg decoder for video stream");
        }
#if defined(__APPLE__)
        codec = SelectAppleHardwareDecoder(codec, &m_hw_pixel_format);
        if (codec == nullptr) {
            avformat_close_input(&format_context);
            return SetError(error, "FFmpeg decoder does not advertise VideoToolbox hardware decode");
        }
#endif

        AVCodecContext* codec_context = avcodec_alloc_context3(codec);
        if (codec_context == nullptr) {
            avformat_close_input(&format_context);
            return SetError(error, "failed to allocate FFmpeg decoder context");
        }

        if (const int result = avcodec_parameters_to_context(codec_context, video_stream->codecpar);
            result < 0) {
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            return SetError(error, "failed to copy FFmpeg codec parameters: " + AvErrorString(result));
        }

#if defined(__APPLE__)
        codec_context->get_format = SelectAppleHardwareFormat;
        codec_context->opaque = &m_hw_pixel_format;
        if (!CreateVideoToolboxDeviceContext(&m_hw_device_context, error)) {
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            return false;
        }
        codec_context->hw_device_ctx = av_buffer_ref(m_hw_device_context);
        if (codec_context->hw_device_ctx == nullptr) {
            av_buffer_unref(&m_hw_device_context);
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            return SetError(error, "failed to retain FFmpeg VideoToolbox device context");
        }
#endif

        if (const int result = avcodec_open2(codec_context, codec, nullptr); result < 0) {
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            av_buffer_unref(&m_hw_device_context);
            return SetError(error, "failed to open FFmpeg decoder: " + AvErrorString(result));
        }

        AVPacket* packet = av_packet_alloc();
        AVFrame*  frame = av_frame_alloc();
        if (packet == nullptr || frame == nullptr) {
            av_packet_free(&packet);
            av_frame_free(&frame);
            avcodec_free_context(&codec_context);
            avformat_close_input(&format_context);
            av_buffer_unref(&m_hw_device_context);
            return SetError(error, "failed to allocate FFmpeg packet/frame buffers");
        }

        m_format_context = format_context;
        m_codec_context = codec_context;
        m_video_stream = video_stream;
        m_display_matrix = StreamDisplayMatrix(video_stream);
        m_video_stream_index = video_stream_index;
        m_packet = packet;
        m_frame = frame;
        m_duration_seconds = ProbeDurationSeconds(format_context, video_stream);
        m_frame_duration_seconds = ProbeFrameDurationSeconds(video_stream);
        // The declared rates seed the estimator as an upper bound on the
        // period; decoded timestamps are what actually unlock pacing.
        m_pacing.Reset(ProbeShortestFrameDurationSeconds(video_stream));
        return true;
    }

    void closeDecoder()
    {
        if (m_packet != nullptr) av_packet_free(&m_packet);
        if (m_frame != nullptr) av_frame_free(&m_frame);
        if (m_codec_context != nullptr) avcodec_free_context(&m_codec_context);
        if (m_format_context != nullptr) avformat_close_input(&m_format_context);
        if (m_hw_device_context != nullptr) av_buffer_unref(&m_hw_device_context);
        m_video_stream = nullptr;
        m_video_stream_index = -1;
    }

    void stop()
    {
        // Published before the lock so the decode thread's inner loops and the
        // libavformat interrupt callback observe it without waiting on us.
        m_cancel_requested.store(true, std::memory_order_relaxed);
        {
            std::lock_guard lock(m_mutex);
            if (!m_running && !m_decode_thread.joinable()) return;
            m_stop_requested = true;
            m_running = false;
            m_condition.notify_all();
        }
        if (m_decode_thread.joinable()) m_decode_thread.join();
    }

    void releaseFrameSlot(DecodedFrameSlot* slot)
    {
        if (slot == nullptr) return;
        ReleaseAppleVideoFrame(&slot->frame);
        slot->ready = false;
        slot->pts_seconds = 0.0;
        slot->absolute_seconds = 0.0;
        slot->loop_index = 0;
        slot->frame = {};
    }

    void clearPendingFramesLocked()
    {
        for (auto& slot : m_pending_frames) {
            releaseFrameSlot(&slot);
        }
        m_pending_frames.clear();
    }

    void clearDisplayFrameLocked()
    {
        if (!m_display_frame_ready) return;
        releaseFrameSlot(&m_display_frame);
        m_display_frame_ready = false;
    }

    void clearFrames()
    {
        std::lock_guard lock(m_mutex);
        clearPendingFramesLocked();
        clearDisplayFrameLocked();
    }

    [[nodiscard]] double currentDesiredAbsoluteLocked() const
    {
        return std::max(0.0, m_scene_absolute_seconds);
    }

    [[nodiscard]] double currentDesiredSecondsLocked() const
    {
        if (!m_clock_initialized) return 0.0;
        return WrapSeconds(currentDesiredAbsoluteLocked(), m_duration_seconds);
    }

    [[nodiscard]] double presentationSlackSeconds() const
    {
        return std::min(0.001, m_frame_duration_seconds * 0.1);
    }

    [[nodiscard]] double latestBufferedAbsoluteLocked() const
    {
        if (!m_pending_frames.empty()) return m_pending_frames.back().absolute_seconds;
        if (m_display_frame_ready) return m_display_frame.absolute_seconds;
        return -std::numeric_limits<double>::infinity();
    }

    void requestSeekLocked(double absolute_seconds)
    {
        m_requested_seek_absolute_seconds = std::max(0.0, absolute_seconds);
        m_seek_requested = true;
        m_seek_awaiting_frame = true;
        m_seek_requested_at = std::chrono::steady_clock::now();
        ++m_seek_ticket;
        ++m_seek_request_count;
        clearPendingFramesLocked();
    }

    [[nodiscard]] double secondsSinceSeekRequestedLocked() const
    {
        return std::chrono::duration<double>(std::chrono::steady_clock::now() - m_seek_requested_at).count();
    }

    /// Whether a seek that has been asked for and has not yet delivered a frame
    /// is still fetching what the clock wants (`SeekOnItsWayCoversClock`).
    ///
    /// Asked for on every call of a draw, a seek that takes longer than the time
    /// between two draws, as one of a large clip does, would never land, and the
    /// display would stay on the frame it had.
    [[nodiscard]] bool seekInFlightCoversLocked(double desired_absolute_seconds,
                                                double backward_slack,
                                                double forward_slack) const
    {
        if (!m_seek_awaiting_frame) return false;
        return SeekOnItsWayCoversClock(m_requested_seek_absolute_seconds, desired_absolute_seconds,
                                       secondsSinceSeekRequestedLocked(), m_playback_state.rate,
                                       backward_slack, forward_slack);
    }

    [[nodiscard]] bool displayFrameCoversDesiredLocked(double desired_absolute_seconds) const
    {
        if (!m_display_frame_ready) return false;
        if (desired_absolute_seconds + presentationSlackSeconds() < m_display_frame.absolute_seconds) {
            return false;
        }

        double display_end_absolute_seconds =
            m_display_frame.absolute_seconds + m_frame_duration_seconds;
        if (!m_pending_frames.empty() &&
            m_pending_frames.front().absolute_seconds > m_display_frame.absolute_seconds) {
            display_end_absolute_seconds = m_pending_frames.front().absolute_seconds;
        }

        return desired_absolute_seconds <
            display_end_absolute_seconds + presentationSlackSeconds();
    }

    bool promoteNextFrameLocked()
    {
        if (m_pending_frames.empty()) return false;

        auto next_frame = std::move(m_pending_frames.front());
        m_pending_frames.pop_front();
        if (m_display_frame_ready) {
            if (next_frame.loop_index > m_display_frame.loop_index) {
                m_loop_count += next_frame.loop_index - m_display_frame.loop_index;
            }
            releaseFrameSlot(&m_display_frame);
        }

        m_display_frame = std::move(next_frame);
        m_display_frame_ready = true;
        return true;
    }

    bool seekDecoderToAbsolute(double absolute_seconds, std::string* error)
    {
        const double clamped_absolute_seconds = std::max(0.0, absolute_seconds);
        const double wrapped_seconds = WrapSeconds(clamped_absolute_seconds, m_duration_seconds);
        if (!seekToSeconds(wrapped_seconds, error)) return false;

        // The packet the pump may still be holding belongs to the position we
        // just left, so the seek is what releases it.
        m_pump.ResetForSeek();
        m_pump.setLoopIndex(
            m_duration_seconds > 0.0
                ? static_cast<uint64_t>(std::floor(clamped_absolute_seconds / m_duration_seconds))
                : 0);
        return true;
    }

    bool seekToSeconds(double seconds, std::string* error)
    {
        if (m_format_context == nullptr || m_codec_context == nullptr || m_video_stream == nullptr) {
            return SetError(error, "FFmpeg decoder is not initialized");
        }

        const int64_t target_timestamp = av_rescale_q(
            static_cast<int64_t>(seconds * static_cast<double>(AV_TIME_BASE)),
            AVRational { 1, AV_TIME_BASE },
            m_video_stream->time_base);
        if (const int result = av_seek_frame(
                m_format_context,
                m_video_stream_index,
                std::max<int64_t>(0, target_timestamp),
                AVSEEK_FLAG_BACKWARD);
            result < 0) {
            return SetError(error, "failed to seek FFmpeg video stream: " + AvErrorString(result));
        }

        avcodec_flush_buffers(m_codec_context);
        av_frame_unref(m_frame);
        av_packet_unref(m_packet);
        return true;
    }

    DecodeOutcome decodeNextFrame(double minimum_absolute_seconds,
                                  DecodedFrameSlot* out,
                                  std::string* error)
    {
        if (out == nullptr) {
            SetError(error, "decoded frame output must not be null");
            return DecodeOutcome::Failed;
        }
        bool enforce_minimum =
            std::isfinite(minimum_absolute_seconds) && minimum_absolute_seconds > 0.0;
        const uint64_t loop_index_at_entry = m_pump.loopIndex();

        while (true) {
            switch (m_pump.NextFrame(error)) {
            case VideoDecodePump::Outcome::Cancelled:
                return DecodeOutcome::Cancelled;
            case VideoDecodePump::Outcome::Failed:
                return DecodeOutcome::Failed;
            case VideoDecodePump::Outcome::Frame:
                break;
            }

            const uint64_t loop_index = m_pump.loopIndex();
            const double frame_pts_seconds =
                FramePtsSeconds(
                    m_frame,
                    m_video_stream->time_base,
                    WrapSeconds(minimum_absolute_seconds, m_duration_seconds));
            const double frame_absolute_seconds =
                (m_duration_seconds > 0.0
                     ? static_cast<double>(loop_index) * m_duration_seconds
                     : 0.0) + frame_pts_seconds;
            if (enforce_minimum &&
                frame_absolute_seconds + m_frame_duration_seconds < minimum_absolute_seconds) {
                av_frame_unref(m_frame);
                // A requested position past everything this stream contains
                // must not filter frames forever: once a full loop has been
                // decoded without a match, take the next frame.
                if (loop_index > loop_index_at_entry) enforce_minimum = false;
                continue;
            }

            VideoTextureFrame frame {};
            if (!ExtractAppleVideoFrame(m_frame, &frame, error)) {
                av_frame_unref(m_frame);
                return DecodeOutcome::Failed;
            }

            if (m_display_matrix) {
                const auto transform = ResolveVideoDisplayTransform(*m_display_matrix, frame.width, frame.height);
                if (! transform) {
                    ReleaseAppleVideoFrame(&frame);
                    av_frame_unref(m_frame);
                    SetError(error, "video display transform is not a valid affine transform");
                    return DecodeOutcome::Failed;
                }
                frame.display_transform = *transform;
            }
            frame.pts_seconds = frame_absolute_seconds;
            out->frame = frame;
            out->pts_seconds = frame_absolute_seconds;
            out->absolute_seconds = frame_absolute_seconds;
            out->loop_index = loop_index;
            out->ready = true;
            av_frame_unref(m_frame);
            return DecodeOutcome::Frame;
        }
    }

    void queueDecodedFrame(DecodedFrameSlot frame_slot, uint64_t seek_ticket)
    {
        std::lock_guard lock(m_mutex);
        if (m_stop_requested || seek_ticket != m_seek_ticket) {
            releaseFrameSlot(&frame_slot);
            return;
        }

        if (m_seek_awaiting_frame) {
            m_seek_awaiting_frame = false;
            m_seek_landing_lag_seconds =
                ClockRunOnSeconds(secondsSinceSeekRequestedLocked(), m_playback_state.rate);
        }
        frame_slot.frame.generation = m_next_generation++;
        ++m_decoded_frame_count;
        // Evidence for pacing comes from here, where a real decoded timestamp
        // exists. Deltas across a loop seam or a seek describe the seam, not
        // the content, so the run identity travels with the sample.
        m_pacing.Observe(frame_slot.absolute_seconds, frame_slot.loop_index, seek_ticket);
        m_pending_frames.push_back(std::move(frame_slot));
        if (!m_display_frame_ready) {
            promoteNextFrameLocked();
        }
        m_condition.notify_all();
    }

    void fail(std::string error)
    {
        // A decode thread that dies after the first frame is otherwise
        // invisible: `refreshFrame` keeps answering with the frame already on
        // screen, so the wallpaper freezes without a word anywhere. The
        // message is recorded once, by the first failure to reach here.
        std::string reported;
        {
            std::lock_guard lock(m_mutex);
            if (m_last_error.empty()) {
                m_last_error = std::move(error);
                reported     = m_last_error;
            }
            m_running = false;
            m_condition.notify_all();
        }
        if (reported.empty()) return;
        LOG_ERROR("video decoding stopped for \"%s\": %s",
                  m_debug_label.c_str(),
                  reported.c_str());
    }

    void decodeLoop()
    {
        while (true) {
            double minimum_absolute_seconds = -std::numeric_limits<double>::infinity();
            bool   perform_seek = false;
            double seek_absolute_seconds = 0.0;
            uint64_t decode_seek_ticket = 0;

            {
                std::unique_lock lock(m_mutex);
                m_condition.wait(lock, [this]() {
                    return m_stop_requested ||
                        m_seek_requested ||
                        m_pending_frames.size() < kDecodedFrameQueueCapacity ||
                        !m_display_frame_ready;
                });
                if (m_stop_requested) break;
                decode_seek_ticket = m_seek_ticket;
                if (m_seek_requested) {
                    perform_seek = true;
                    seek_absolute_seconds = m_requested_seek_absolute_seconds;
                    m_seek_requested = false;
                    minimum_absolute_seconds = seek_absolute_seconds;
                }
            }

            if (perform_seek) {
                std::string error;
                if (!seekDecoderToAbsolute(seek_absolute_seconds, &error)) {
                    fail(std::move(error));
                    break;
                }
            }

            DecodedFrameSlot frame_slot {};
            std::string      error;
            const DecodeOutcome outcome =
                decodeNextFrame(minimum_absolute_seconds, &frame_slot, &error);
            if (outcome == DecodeOutcome::Cancelled) break;
            if (outcome == DecodeOutcome::Failed) {
                fail(std::move(error));
                break;
            }
            queueDecodedFrame(std::move(frame_slot), decode_seek_ticket);
        }
    }

private:
    std::string                      m_debug_label;
    std::vector<char>                m_payload;
    std::filesystem::path            m_media_path;
    std::string                      m_initial_error;
    mutable std::mutex               m_mutex;
    std::condition_variable          m_condition;
    VideoPlaybackState               m_playback_state {};
    double                           m_scene_absolute_seconds { 0.0 };
    std::chrono::steady_clock::time_point m_clock_base_time {};
    double                           m_clock_base_seconds { 0.0 };
    bool                             m_clock_initialized { false };
    double                           m_duration_seconds { 0.0 };
    double                           m_frame_duration_seconds { 1.0 / 60.0 };
    /// Pacing evidence: declared rates as an upper bound on the period plus the
    /// shortest gap actually decoded. Reports unknown until it has enough
    /// samples, which keeps an unproven stream on the fixed cadence.
    /// Process-unique, so two decoders opened from the same file are two
    /// identities. Never derived from the path or from content.
    const uint64_t                   m_instance_id { NextVideoSourceInstanceId() };
    VideoFramePacingEstimator        m_pacing;
    uint64_t                         m_decoded_frame_count { 0 };
    uint64_t                         m_seek_request_count { 0 };
    uint64_t                         m_loop_count { 0 };
    uint64_t                         m_next_generation { 1 };
    std::deque<DecodedFrameSlot>     m_pending_frames;
    DecodedFrameSlot                 m_display_frame {};
    bool                             m_display_frame_ready { false };
    bool                             m_seek_requested { false };
    /// Set by a seek request and cleared by the first frame decoded for it.
    bool                             m_seek_awaiting_frame { false };
    std::chrono::steady_clock::time_point m_seek_requested_at {};
    /// How far behind the clock the last seek that landed left its first frame:
    /// the clip's time that passed while it was being fetched.
    double                           m_seek_landing_lag_seconds { 0.0 };
    double                           m_requested_seek_absolute_seconds { 0.0 };
    uint64_t                         m_seek_ticket { 0 };
    bool                             m_running { false };
    bool                             m_stop_requested { false };
    /// Read by the decode thread's inner loops and by the libavformat
    /// interrupt callback, so it cannot be guarded by `m_mutex`.
    std::atomic<bool>                m_cancel_requested { false };
    bool                             m_primed { false };
    std::once_flag                   m_prime_once;
    bool                             m_prime_succeeded { false };
    std::string                      m_prime_error;
    std::thread                      m_decode_thread;
    std::string                      m_last_error;
    AVFormatContext*                 m_format_context { nullptr };
    AVCodecContext*                  m_codec_context { nullptr };
    AVBufferRef*                     m_hw_device_context { nullptr };
    AVStream*                        m_video_stream { nullptr };
    std::optional<std::array<int32_t, 9>> m_display_matrix;
    int                              m_video_stream_index { -1 };
    AVPacket*                        m_packet { nullptr };
    AVFrame*                         m_frame { nullptr };
    AVPixelFormat                    m_hw_pixel_format { AV_PIX_FMT_NONE };
    /// Declared last so the decoder handles above are initialized before the
    /// source that borrows them. Both are owned by the decode thread.
    DecodeSource                     m_decode_source { *this };
    VideoDecodePump           m_pump { m_decode_source };
};

FfmpegVideoTextureSource::FfmpegVideoTextureSource(const Image& image)
    : m_impl(std::make_unique<Impl>(image))
{
}

FfmpegVideoTextureSource::FfmpegVideoTextureSource(std::string media_path)
    : m_impl(std::make_unique<Impl>(std::move(media_path)))
{
}

FfmpegVideoTextureSource::~FfmpegVideoTextureSource() = default;

bool FfmpegVideoTextureSource::prime(std::string* error)
{
    return m_impl->prime(error);
}

bool FfmpegVideoTextureSource::syncPlayback(const VideoPlaybackState& state, std::string* error)
{
    return m_impl->syncPlayback(state, error);
}

bool FfmpegVideoTextureSource::refreshFrame(std::string* error)
{
    return m_impl->refreshFrame(error);
}

VideoTextureFrame FfmpegVideoTextureSource::currentFrame() const
{
    return m_impl->currentFrame();
}

bool FfmpegVideoTextureSource::retainCurrentFrame(VideoTextureFrame* out) const
{
    return m_impl->retainCurrentFrame(out);
}

double FfmpegVideoTextureSource::durationSeconds() const
{
    return m_impl->durationSeconds();
}

double FfmpegVideoTextureSource::playbackSeconds() const
{
    return m_impl->playbackSeconds();
}

uint64_t FfmpegVideoTextureSource::loopCount() const
{
    return m_impl->loopCount();
}

double FfmpegVideoTextureSource::frameDurationSeconds() const
{
    return m_impl->frameDurationSeconds();
}

VideoSourceStats FfmpegVideoTextureSource::sourceStats() const
{
    return m_impl->sourceStats();
}

std::shared_ptr<VideoTextureSource> CreateVideoTextureSource(const Image& image,
                                                             std::string* error)
{
    if (!image.header.isVideo) {
        SetError(error, "image is not marked as a video texture");
        return nullptr;
    }

    return std::make_shared<FfmpegVideoTextureSource>(image);
}

std::shared_ptr<Image> CreateVideoProjectImage(const std::filesystem::path& project_directory,
                                               std::string_view             file_name,
                                               std::string*                 error)
{
    if (file_name.empty()) {
        SetError(error, "video project file entry must not be empty");
        return nullptr;
    }

    std::filesystem::path media_path(file_name);
    if (media_path.is_relative()) media_path = project_directory / media_path;

    // Both sides are canonicalised before they are compared, so a symlink is
    // followed first and a link that leaves the project is rejected rather
    // than read.
    std::error_code ec;
    const std::filesystem::path resolved_media = std::filesystem::canonical(media_path, ec);
    if (ec) {
        SetError(error,
                 std::string("failed to open video project media file: ") + media_path.string());
        return nullptr;
    }
    const std::filesystem::path resolved_project = std::filesystem::canonical(project_directory, ec);
    if (ec) {
        SetError(error,
                 std::string("failed to open video project media file: ") + media_path.string());
        return nullptr;
    }

    const std::filesystem::path relative = resolved_media.lexically_relative(resolved_project);
    if (relative.empty() || relative.begin()->native() == "..") {
        SetError(error,
                 std::string("video project media file escapes the project directory: ") +
                     resolved_media.string());
        return nullptr;
    }

    if (!std::filesystem::is_regular_file(resolved_media, ec) || ec) {
        SetError(error,
                 std::string("failed to open video project media file: ") + media_path.string());
        return nullptr;
    }
    if (std::filesystem::file_size(resolved_media, ec) == 0 || ec) {
        SetError(error,
                 std::string("video project media file is empty: ") + media_path.string());
        return nullptr;
    }

    uint32_t source_width  = 0;
    uint32_t source_height = 0;
    if (!ProbeVideoFileDimensions(resolved_media.string(), &source_width, &source_height, error)) {
        return nullptr;
    }

    auto image = std::make_shared<Image>();
    image->key = std::string(file_name);
    // The wallpaper's own file is the decode input. Nothing reads it into this
    // process and nothing writes a second copy of it, which is why the image
    // carries no slots.
    image->videoFilePath            = resolved_media.string();
    image->header.isVideo           = true;
    image->header.videoAudioEnabled = true;
    image->header.count             = 1;
    image->header.sample.wrapS      = TextureWrap::CLAMP_TO_EDGE;
    image->header.sample.wrapT      = TextureWrap::CLAMP_TO_EDGE;
    image->header.sample.minFilter  = TextureFilter::LINEAR;
    image->header.sample.magFilter  = TextureFilter::LINEAR;
    image->header.width             = static_cast<i32>(source_width);
    image->header.height            = static_cast<i32>(source_height);
    image->header.mapWidth          = static_cast<i32>(source_width);
    image->header.mapHeight         = static_cast<i32>(source_height);
    return image;
}

bool ProbeVideoFileDimensions(std::string_view media_path,
                              uint32_t*        width,
                              uint32_t*        height,
                              std::string*     error)
{
    if (media_path.empty()) return SetError(error, "video media path must not be empty");

    AVFormatContext* format_context = nullptr;
    if (const int result = avformat_open_input(&format_context,
                                               std::string(media_path).c_str(),
                                               nullptr,
                                               nullptr);
        result < 0) {
        return SetError(error, "failed to open FFmpeg input: " + AvErrorString(result));
    }

    if (const int result = avformat_find_stream_info(format_context, nullptr); result < 0) {
        avformat_close_input(&format_context);
        return SetError(error, "failed to read FFmpeg stream info: " + AvErrorString(result));
    }

    const int video_stream_index =
        av_find_best_stream(format_context, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (video_stream_index < 0) {
        avformat_close_input(&format_context);
        return SetError(error, "failed to find FFmpeg video stream: " + AvErrorString(video_stream_index));
    }

    AVStream* stream = format_context->streams[video_stream_index];
    const bool ok = ProbeStreamDimensions(stream, width, height, error);
    avformat_close_input(&format_context);
    return ok;
}

bool ProbeVideoFileMetadata(std::string_view media_path,
                            VideoMetadata*   out,
                            std::string*     error)
{
    if (out == nullptr) return SetError(error, "video metadata output must not be null");
    if (media_path.empty()) return SetError(error, "video media path must not be empty");
    if (auto mismatch = FfmpegAbiMismatch(); !mismatch.empty()) {
        return SetError(error, std::move(mismatch));
    }

    AVFormatContext* format_context = nullptr;
    if (const int result = avformat_open_input(&format_context,
                                               std::string(media_path).c_str(),
                                               nullptr,
                                               nullptr);
        result < 0) {
        return SetError(error, "failed to open FFmpeg input: " + AvErrorString(result));
    }

    if (const int result = avformat_find_stream_info(format_context, nullptr); result < 0) {
        avformat_close_input(&format_context);
        return SetError(error, "failed to read FFmpeg stream info: " + AvErrorString(result));
    }

    const int video_stream_index =
        av_find_best_stream(format_context, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (video_stream_index < 0) {
        avformat_close_input(&format_context);
        return SetError(error, "failed to find FFmpeg video stream: " + AvErrorString(video_stream_index));
    }

    AVStream* stream = format_context->streams[video_stream_index];
    const bool ok = ProbeStreamDimensions(stream, &out->width, &out->height, error);
    if (ok) {
        out->duration_seconds = ProbeDurationSeconds(format_context, stream);
    }
    avformat_close_input(&format_context);
    return ok;
}

} // namespace wallpaper::video
