#pragma once

#include "Video/VideoFrameBackend.hpp"
#include "Video/VideoFramePacing.hpp"
#include "Video/VideoTextureSource.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace wallpaper::video
{

/// A `VideoTextureSource` that plays a stream on a clock: one decode thread
/// feeding a bounded queue of frames, the frame the clock asks for promoted to
/// the display slot, seeks when the clock jumps, loops at the end. Where the
/// frames come from is the `VideoFrameBackend`'s business.
class ClockedVideoSource : public VideoTextureSource {
public:
    /// `debug_label` names the media in logs. A non-empty `initial_error` makes
    /// `prime` fail with it, for a source that could not even be described.
    ClockedVideoSource(std::unique_ptr<VideoFrameBackend> backend, std::string debug_label,
                       std::string initial_error = {});
    ~ClockedVideoSource() override;

    bool prime(std::string* error) override;
    bool syncPlayback(const VideoPlaybackState& state, std::string* error) override;
    bool refreshFrame(std::string* error) override;
    [[nodiscard]] VideoTextureFrame currentFrame() const override;
    [[nodiscard]] bool retainCurrentFrame(VideoTextureFrame* out) const override;
    [[nodiscard]] double durationSeconds() const override;
    [[nodiscard]] double playbackSeconds() const override;
    [[nodiscard]] uint64_t loopCount() const override;
    [[nodiscard]] double frameDurationSeconds() const override;
    [[nodiscard]] VideoSourceStats sourceStats() const override;

private:
    static constexpr size_t kDecodedFrameQueueCapacity = 8;

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

    /// Everything the source knows about seeks: the request the decode thread has yet to
    /// take, the wait for the first frame of the latest request, and the totals.
    struct SeekLedger {
        double   target { 0.0 };        ///< absolute clock the latest request asked for
        bool     unclaimed { false };   ///< asked for and not yet taken up by the decode thread
        bool     unlanded { false };    ///< asked for and its first frame has not arrived
        std::chrono::steady_clock::time_point asked_at {};
        /// How far behind the clock the last seek that landed left its first frame:
        /// the clip's time that passed while it was being fetched.
        double   landing_lag { 0.0 };
        uint64_t epoch { 0 };           ///< identity of the latest request; decoded frames carry it
        uint64_t requests { 0 };        ///< requests made, counted when made

        /// Records a new request; frames decoded under any earlier epoch become stale.
        void Arm(double absolute_target, std::chrono::steady_clock::time_point now)
        {
            ++requests;
            ++epoch;
            asked_at  = now;
            unlanded  = true;
            unclaimed = true;
            target    = absolute_target;
        }
    };

    bool primeOnce(std::string* error);
    void stop();
    void releaseFrameSlot(DecodedFrameSlot* slot);
    void clearPendingFramesLocked();
    void clearDisplayFrameLocked();
    void clearFrames();
    [[nodiscard]] double currentDesiredAbsoluteLocked() const;
    [[nodiscard]] double currentDesiredSecondsLocked() const;
    [[nodiscard]] double presentationSlackSeconds() const;
    [[nodiscard]] double latestBufferedAbsoluteLocked() const;
    void requestSeekLocked(double absolute_seconds);
    [[nodiscard]] double secondsSinceSeekRequestedLocked() const;
    [[nodiscard]] bool seekInFlightCoversLocked(double desired_absolute_seconds, double backward_slack,
                                                double forward_slack) const;
    [[nodiscard]] bool displayFrameCoversDesiredLocked(double desired_absolute_seconds) const;
    bool promoteNextFrameLocked();
    bool seekBackendToAbsolute(double absolute_seconds, std::string* error);
    DecodeOutcome decodeNextFrame(double minimum_absolute_seconds, DecodedFrameSlot* out, std::string* error);
    void queueDecodedFrame(DecodedFrameSlot frame_slot, uint64_t seek_ticket);
    void fail(std::string error);
    [[nodiscard]] bool stopRequested() const;
    void decodeLoop();

    std::unique_ptr<VideoFrameBackend> m_backend;
    // Names the media in logs; a non-empty error makes `prime` fail with it.
    std::string m_debug_label;
    std::string m_initial_error;

    // Shared between the clock's callers and the decode thread.
    mutable std::mutex      m_mutex;
    std::condition_variable m_condition;
    VideoPlaybackState      m_playback_state {};

    // The playback clock: where the scene is, and the pair (wall time, media seconds) it is
    // measured from once it has started.
    double                                m_scene_absolute_seconds { 0.0 };
    std::chrono::steady_clock::time_point m_clock_base_time {};
    double                                m_clock_base_seconds { 0.0 };
    bool                                  m_clock_initialized { false };

    double m_duration_seconds { 0.0 };
    // Until the first decode the frame period is assumed to be a sixtieth of a second.
    double m_frame_duration_seconds { 1.0 / 60.0 };

    /// Process-unique, so two decoders opened from the same file are two
    /// identities. Never derived from the path or from content.
    const uint64_t                   m_instance_id;
    /// Pacing evidence: declared rates as an upper bound on the period plus the
    /// shortest gap actually decoded. Reports unknown until it has enough
    /// samples, which keeps an unproven stream on the fixed cadence.
    VideoFramePacingEstimator        m_pacing;
    uint64_t                         m_decoded_frame_count { 0 };
    uint64_t                         m_loop_count { 0 };
    uint64_t                         m_next_generation { 1 };
    std::deque<DecodedFrameSlot>     m_pending_frames;
    DecodedFrameSlot                 m_display_frame {};
    bool                             m_display_frame_ready { false };
    SeekLedger                       m_seek;
    bool                             m_running { false };
    bool                             m_stop_requested { false };
    bool                             m_primed { false };
    /// Counted in `OpenVideoDecoderCount` from a successful prime until destruction.
    bool                             m_counted_open { false };
    std::once_flag                   m_prime_once;
    bool                             m_prime_succeeded { false };
    std::string                      m_prime_error;
    std::thread                      m_decode_thread;
    std::string                      m_last_error;
};

} // namespace wallpaper::video
