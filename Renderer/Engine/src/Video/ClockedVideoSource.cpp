// Clean-room implementation from the WallpaperMachine spec e5-text-audio-video-runtime.md; written without access to the original source.
#include "Video/ClockedVideoSource.hpp"

#include "Platform/Apple/VideoFrameInterop.hpp"
#include "Utils/Logging.h"
#include "Video/VideoSeekPolicy.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <exception>
#include <limits>
#include <utility>

namespace wallpaper::video
{
namespace
{

constexpr auto kPrimeTimeout = std::chrono::seconds(2);

bool SetError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
    return false;
}

double WrapSeconds(double seconds, double duration_seconds)
{
    if (!(duration_seconds > 0.0) || !std::isfinite(duration_seconds) || !std::isfinite(seconds) ||
        seconds <= 0.0) {
        return 0.0;
    }
    const double wrapped = std::fmod(seconds, duration_seconds);
    return wrapped >= duration_seconds ? 0.0 : wrapped;
}

/// Identity of a running decoder instance. Monotonic and never reused, so a
/// report can de-duplicate one source's work across several consumers without
/// ever merging two decoders that happen to read the same file.
uint64_t NextVideoSourceInstanceId()
{
    static std::atomic<uint64_t> next { 1 };
    return next.fetch_add(1, std::memory_order_relaxed);
}

std::atomic<int> g_open_decoders { 0 };

} // namespace

int OpenVideoDecoderCount() { return g_open_decoders.load(std::memory_order_relaxed); }

ClockedVideoSource::ClockedVideoSource(std::unique_ptr<VideoFrameBackend> backend,
                                       std::string                        debug_label,
                                       std::string                        initial_error)
    : m_backend(std::move(backend)),
      m_debug_label(std::move(debug_label)),
      m_initial_error(std::move(initial_error)),
      m_instance_id(NextVideoSourceInstanceId())
{
    if (m_backend == nullptr && m_initial_error.empty()) m_initial_error = "video source has no decoder";
}

ClockedVideoSource::~ClockedVideoSource()
{
    stop();
    clearFrames();
    if (m_backend != nullptr) m_backend->close();
    if (m_counted_open) g_open_decoders.fetch_sub(1, std::memory_order_relaxed);
}

bool ClockedVideoSource::prime(std::string* error)
{
    // Every consumer waits for the same complete attempt, including its
    // failure. Decoder handles and the worker thread have one initializer.
    std::call_once(m_prime_once, [this] {
        try {
            m_prime_succeeded = primeOnce(&m_prime_error);
        } catch (const std::exception& exception) {
            m_prime_error = std::string("failed to initialize video: ") + exception.what();
        }
        if (! m_prime_succeeded) {
            stop();
            clearFrames();
            if (m_backend != nullptr) m_backend->close();
        }
    });
    if (m_prime_succeeded) return true;
    return SetError(error, m_prime_error);
}

bool ClockedVideoSource::primeOnce(std::string* error)
{
    if (!m_initial_error.empty()) return SetError(error, m_initial_error);
    if (m_backend == nullptr) return SetError(error, "video source has no decoder");
    std::string open_error;
    if (!m_backend->open(&open_error)) {
        return SetError(error, open_error.empty() ? std::string("failed to open the video") : std::move(open_error));
    }
    const auto info = m_backend->streamInfo();
    m_duration_seconds = (info.duration_seconds > 0.0 && std::isfinite(info.duration_seconds)) ? info.duration_seconds : 0.0;
    m_frame_duration_seconds = (info.frame_duration_seconds > 0.0 && std::isfinite(info.frame_duration_seconds))
        ? info.frame_duration_seconds
        : 1.0 / 60.0;
    {
        std::lock_guard lock(m_mutex);
        m_pacing.Reset(info.shortest_declared_period_seconds);
        // The clock starts at the head: a clock handed over before the open is given again
        // by the first sync after it, which is what asks for the seek.
        m_scene_absolute_seconds = 0.0;
        m_playback_state         = VideoPlaybackState {};
        m_stop_requested         = false;
        m_running                = true;
    }
    m_decode_thread = std::thread([this] { decodeLoop(); });

    std::unique_lock lock(m_mutex);
    m_condition.wait_for(lock, kPrimeTimeout, [this] { return m_display_frame_ready || !m_last_error.empty(); });
    if (!m_display_frame_ready) {
        return SetError(error, m_last_error.empty() ? std::string("timed out waiting for the first video frame")
                                                    : m_last_error);
    }
    m_primed        = true;
    m_counted_open  = true;
    g_open_decoders.fetch_add(1, std::memory_order_relaxed);
    return true;
}

bool ClockedVideoSource::syncPlayback(const VideoPlaybackState& state, std::string* error)
{
    if (state.rate < 0.0f) return SetError(error, "negative video playback rates are not supported");
    std::lock_guard lock(m_mutex);
    if (!m_last_error.empty()) return SetError(error, m_last_error);
    m_playback_state              = state;
    m_playback_state.rate         = std::max(0.0f, state.rate);
    m_scene_absolute_seconds      = std::max(0.0, state.scene_elapsed_seconds);
    m_playback_state.scene_elapsed_seconds = m_scene_absolute_seconds;
    m_clock_initialized           = true;
    if (m_display_frame_ready) {
        const double desired   = currentDesiredAbsoluteLocked();
        const double threshold = std::max(0.5, m_frame_duration_seconds * 8.0);
        if (desired < m_display_frame.absolute_seconds - threshold) {
            clearDisplayFrameLocked();
            requestSeekLocked(desired);
            m_condition.notify_all();
        }
    }
    return true;
}

bool ClockedVideoSource::refreshFrame(std::string* error)
{
    std::unique_lock lock(m_mutex);
    if (!m_last_error.empty() && !m_display_frame_ready) return SetError(error, m_last_error);
    if (!m_primed) return SetError(error, "video source is not open");

    const auto   started  = std::chrono::steady_clock::now();
    const double desired  = currentDesiredAbsoluteLocked();
    const double period   = m_frame_duration_seconds;
    const double slack    = presentationSlackSeconds();
    const double backward = std::max(0.05, period * 2.0);
    const double forward  = ForwardResyncSeconds(period, static_cast<double>(kDecodedFrameQueueCapacity),
                                                 m_seek.landing_lag);

    // A clock that went back past what is shown gets a seek of its own, display emptied first.
    if (m_display_frame_ready && desired < m_display_frame.absolute_seconds - backward) {
        clearDisplayFrameLocked();
        requestSeekLocked(desired);
    }
    // One seek per jump: while a seek is on its way and still fetches what the clock wants, wait for it.
    if (!seekInFlightCoversLocked(desired, backward, forward)) {
        const bool nothing_shown = !m_display_frame_ready;
        if (nothing_shown || desired - latestBufferedAbsoluteLocked() > forward) requestSeekLocked(desired);
    }

    // Every frame that has fallen due is passed over except the last, which is shown.
    bool promoted = false;
    while (!m_pending_frames.empty() &&
           (!m_display_frame_ready || m_pending_frames.front().absolute_seconds <= desired + slack)) {
        promoted = promoteNextFrameLocked() || promoted;
    }
    if (promoted || m_seek.unclaimed || !m_display_frame_ready) m_condition.notify_all();
    if (m_display_frame_ready) return true;

    // Nothing is on display: wait for the first frame for a bounded time.
    const auto deadline = started + kPrimeTimeout;
    m_condition.wait_until(lock, deadline, [this, desired] {
        return m_display_frame_ready || displayFrameCoversDesiredLocked(desired) || !m_last_error.empty() ||
               m_stop_requested;
    });
    if (m_display_frame_ready) return true;
    if (!m_last_error.empty()) return SetError(error, m_last_error);
    return SetError(error, "video frame is not ready");
}

VideoTextureFrame ClockedVideoSource::currentFrame() const
{
    std::lock_guard lock(m_mutex);
    return m_display_frame_ready ? m_display_frame.frame : VideoTextureFrame {};
}

bool ClockedVideoSource::retainCurrentFrame(VideoTextureFrame* out) const
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

double ClockedVideoSource::durationSeconds() const
{
    std::lock_guard lock(m_mutex);
    return m_duration_seconds;
}

double ClockedVideoSource::playbackSeconds() const
{
    std::lock_guard lock(m_mutex);
    return currentDesiredSecondsLocked();
}

uint64_t ClockedVideoSource::loopCount() const
{
    std::lock_guard lock(m_mutex);
    return m_loop_count;
}

double ClockedVideoSource::frameDurationSeconds() const
{
    std::lock_guard lock(m_mutex);
    // Zero until enough real presentation timestamps have been seen, which
    // the frame clock reads as "unknown" and answers with the fixed
    // cadence. Declared rates alone never unlock pacing.
    return m_primed ? m_pacing.PeriodSeconds() : 0.0;
}

VideoSourceStats ClockedVideoSource::sourceStats() const
{
    std::lock_guard lock(m_mutex);
    return VideoSourceStats {
        .instance_id = m_instance_id,
        .decoded_frames = m_decoded_frame_count,
        .seek_requests = m_seek.requests,
        .observed_period_seconds = m_pacing.ObservedPeriodSeconds(),
        .observed_samples = m_pacing.SampleCount(),
    };
}

void ClockedVideoSource::stop()
{
    // Published before the lock so the decode thread's inner loops and any
    // blocking read in the backend observe it without waiting on us.
    if (m_backend != nullptr) m_backend->cancel();
    {
        std::lock_guard lock(m_mutex);
        m_stop_requested = true;
        m_running        = false;
        m_condition.notify_all();
    }
    if (m_decode_thread.joinable()) m_decode_thread.join();
}

void ClockedVideoSource::releaseFrameSlot(DecodedFrameSlot* slot)
{
    if (slot == nullptr) return;
    ReleaseAppleVideoFrame(&slot->frame);
    *slot = DecodedFrameSlot {};
}

void ClockedVideoSource::clearPendingFramesLocked()
{
    for (auto& slot : m_pending_frames) releaseFrameSlot(&slot);
    m_pending_frames.clear();
}

void ClockedVideoSource::clearDisplayFrameLocked()
{
    releaseFrameSlot(&m_display_frame);
    m_display_frame_ready = false;
}

void ClockedVideoSource::clearFrames()
{
    std::lock_guard lock(m_mutex);
    clearPendingFramesLocked();
    clearDisplayFrameLocked();
}

double ClockedVideoSource::currentDesiredAbsoluteLocked() const
{
    return std::max(0.0, m_scene_absolute_seconds);
}

double ClockedVideoSource::currentDesiredSecondsLocked() const
{
    return WrapSeconds(currentDesiredAbsoluteLocked(), m_duration_seconds);
}

double ClockedVideoSource::presentationSlackSeconds() const
{
    return std::min(0.001, m_frame_duration_seconds * 0.1);
}

double ClockedVideoSource::latestBufferedAbsoluteLocked() const
{
    if (!m_pending_frames.empty()) return m_pending_frames.back().absolute_seconds;
    return m_display_frame_ready ? m_display_frame.absolute_seconds : 0.0;
}

void ClockedVideoSource::requestSeekLocked(double absolute_seconds)
{
    clearPendingFramesLocked();
    m_seek.Arm(std::max(0.0, absolute_seconds), std::chrono::steady_clock::now());
}

double ClockedVideoSource::secondsSinceSeekRequestedLocked() const
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - m_seek.asked_at).count();
}

/// Whether a seek that has been asked for and has not yet delivered a frame
/// is still fetching what the clock wants (`SeekOnItsWayCoversClock`).
///
/// Asked for on every call of a draw, a seek that takes longer than the time
/// between two draws, as one of a large clip does, would never land, and the
/// display would stay on the frame it had.
bool ClockedVideoSource::seekInFlightCoversLocked(double desired_absolute_seconds,
                                                  double backward_slack,
                                                  double forward_slack) const
{
    if (!m_seek.unlanded) return false;
    return SeekOnItsWayCoversClock(m_seek.target, desired_absolute_seconds,
                                   secondsSinceSeekRequestedLocked(), m_playback_state.rate,
                                   backward_slack, forward_slack);
}

bool ClockedVideoSource::displayFrameCoversDesiredLocked(double desired_absolute_seconds) const
{
    if (!m_display_frame_ready) return false;
    const double slack = presentationSlackSeconds();
    const double start = m_display_frame.absolute_seconds;
    double       end   = start + m_frame_duration_seconds;
    if (!m_pending_frames.empty() && m_pending_frames.front().absolute_seconds > start) {
        end = m_pending_frames.front().absolute_seconds;
    }
    return desired_absolute_seconds + slack >= start && desired_absolute_seconds < end + slack;
}

bool ClockedVideoSource::promoteNextFrameLocked()
{
    if (m_pending_frames.empty()) return false;
    DecodedFrameSlot next = m_pending_frames.front();
    m_pending_frames.pop_front();
    if (m_display_frame_ready && next.loop_index > m_display_frame.loop_index) {
        m_loop_count += next.loop_index - m_display_frame.loop_index;
    }
    releaseFrameSlot(&m_display_frame);
    m_display_frame       = next;
    m_display_frame_ready = true;
    return true;
}

bool ClockedVideoSource::seekBackendToAbsolute(double absolute_seconds, std::string* error)
{
    const double clamped_absolute_seconds = std::max(0.0, absolute_seconds);
    const double wrapped_seconds = WrapSeconds(clamped_absolute_seconds, m_duration_seconds);
    return m_backend->seek(
        wrapped_seconds,
        m_duration_seconds > 0.0
            ? static_cast<uint64_t>(std::floor(clamped_absolute_seconds / m_duration_seconds))
            : 0,
        error);
}

ClockedVideoSource::DecodeOutcome ClockedVideoSource::decodeNextFrame(double minimum_absolute_seconds,
                                                                       DecodedFrameSlot* out,
                                                                       std::string* error)
{
    if (out == nullptr) {
        SetError(error, "decoded frame output must not be null");
        return DecodeOutcome::Failed;
    }
    bool           filter     = std::isfinite(minimum_absolute_seconds) && minimum_absolute_seconds > 0.0;
    const double   fallback   = WrapSeconds(minimum_absolute_seconds, m_duration_seconds);
    const uint64_t start_pass = m_backend->loopIndex();
    for (;;) {
        VideoFrameBackend::DecodedPosition position;
        switch (m_backend->decodeNext(fallback, &position, error)) {
        case VideoFrameBackend::Decode::Cancelled: return DecodeOutcome::Cancelled;
        case VideoFrameBackend::Decode::Failed: return DecodeOutcome::Failed;
        case VideoFrameBackend::Decode::Frame: break;
        }
        const double absolute = (m_duration_seconds > 0.0 ? static_cast<double>(position.loop_index) * m_duration_seconds : 0.0) +
                                position.pts_seconds;
        if (filter && absolute + m_frame_duration_seconds < minimum_absolute_seconds) {
            // Ends before the target: decoded to feed what follows, never shown.
            m_backend->discardFrame();
            // A whole pass without a frame at the target: the target lies beyond the stream.
            if (m_backend->loopIndex() > start_pass) filter = false;
            continue;
        }
        DecodedFrameSlot slot;
        if (!m_backend->takeFrame(&slot.frame, error)) return DecodeOutcome::Failed;
        slot.pts_seconds       = position.pts_seconds;
        slot.absolute_seconds  = absolute;
        slot.loop_index        = position.loop_index;
        slot.frame.pts_seconds = absolute;
        slot.ready             = true;
        *out                   = slot;
        return DecodeOutcome::Frame;
    }
}

void ClockedVideoSource::queueDecodedFrame(DecodedFrameSlot frame_slot, uint64_t seek_epoch)
{
    std::lock_guard lock(m_mutex);
    const bool stale = m_stop_requested || seek_epoch != m_seek.epoch;
    if (stale) {
        releaseFrameSlot(&frame_slot);
        return;
    }

    // The first frame after a request settles the wait for it and times how long it took.
    if (m_seek.unlanded) {
        m_seek.unlanded    = false;
        m_seek.landing_lag = ClockRunOnSeconds(secondsSinceSeekRequestedLocked(), m_playback_state.rate);
    }

    const bool display_was_empty = !m_display_frame_ready;
    frame_slot.ready             = true;
    frame_slot.frame.generation  = m_next_generation;
    m_pacing.Observe(frame_slot.absolute_seconds, frame_slot.loop_index, seek_epoch);
    m_pending_frames.push_back(std::move(frame_slot));
    ++m_next_generation;
    ++m_decoded_frame_count;
    if (display_was_empty) promoteNextFrameLocked();
    m_condition.notify_all();
}

bool ClockedVideoSource::stopRequested() const
{
    std::lock_guard lock(m_mutex);
    return m_stop_requested;
}

void ClockedVideoSource::fail(std::string error)
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

void ClockedVideoSource::decodeLoop()
{
    double target = 0.0;
    for (;;) {
        uint64_t ticket  = 0;
        bool     seeking = false;
        {
            std::unique_lock lock(m_mutex);
            // Nothing to do (queue full, display filled, no seek asked for): no work and no timer.
            m_condition.wait(lock, [this] {
                return m_stop_requested || m_seek.unclaimed ||
                       m_pending_frames.size() < kDecodedFrameQueueCapacity || !m_display_frame_ready;
            });
            if (m_stop_requested) return;
            ticket = m_seek.epoch;
            if (m_seek.unclaimed) {
                m_seek.unclaimed = false;
                seeking          = true;
                target           = m_seek.target;
            }
        }
        std::string error;
        if (seeking && !seekBackendToAbsolute(target, &error)) {
            if (!stopRequested()) fail(error.empty() ? std::string("video seek failed") : std::move(error));
            return;
        }
        DecodedFrameSlot slot;
        switch (decodeNextFrame(target, &slot, &error)) {
        case DecodeOutcome::Cancelled: return;
        case DecodeOutcome::Failed:
            if (!stopRequested()) fail(error.empty() ? std::string("video decoding failed") : std::move(error));
            return;
        case DecodeOutcome::Frame: queueDecodedFrame(std::move(slot), ticket); break;
        }
    }
}

} // namespace wallpaper::video
