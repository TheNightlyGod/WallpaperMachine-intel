#pragma once

#include <cstdint>
#include <string>

namespace wallpaper::video
{

/// Result of one decoder operation, in the send/receive vocabulary of a codec
/// API: `Again` means the decoder is full or empty and the other side must be
/// serviced first, `EndOfStream` that nothing more will come.
enum class DecodeStatus {
    Ok,
    Again,
    EndOfStream,
    Error,
};

/// The decoder operations the pump drives. Implemented over VideoToolbox by
/// `NativeVideoBackend`; implemented by fakes in the tests so the state
/// machine can be exercised without a codec.
///
/// Ownership rule: a packet read by `ReadPacket` stays owned by the source
/// until `ReleasePacket`. The pump releases it only after `SendPacket` reports
/// `Ok`, because `Again` means the decoder did not take the packet and the same
/// packet must be submitted again after output has been drained.
class VideoDecodeSource {
public:
    VideoDecodeSource() = default;
    VideoDecodeSource(const VideoDecodeSource&) = delete;
    VideoDecodeSource& operator=(const VideoDecodeSource&) = delete;
    virtual ~VideoDecodeSource() = default;

    /// Reads the next packet belonging to the selected video stream. Packets of
    /// other streams are consumed and released by the implementation; `Again`
    /// means none was available within this call's own bound.
    virtual DecodeStatus ReadPacket(std::string* error) = 0;
    /// Submits the packet currently held by the source.
    virtual DecodeStatus SendPacket(std::string* error) = 0;
    /// Releases the held packet. Called exactly once per accepted packet.
    virtual void ReleasePacket() = 0;
    /// Submits the null packet that starts draining delayed output.
    virtual DecodeStatus SendDrainRequest(std::string* error) = 0;
    /// Receives one decoded frame into the source's frame slot.
    virtual DecodeStatus ReceiveFrame(std::string* error) = 0;
    /// Flushes decoder buffers and seeks back to the start of the stream for
    /// the next loop.
    virtual bool RestartAtStreamStart(std::string* error) = 0;
    /// Cooperative cancellation, polled between every step.
    [[nodiscard]] virtual bool IsCancelled() const = 0;
};

/// Receive-first decode pump.
///
/// A send/receive decoder requires that output be drained before more input is
/// accepted, that a rejected input packet be resubmitted rather than dropped, and that
/// end of input be followed by a drain request so delayed frames (reordered
/// B-frames in particular) are produced before the stream restarts. Pumping
/// input first and discarding rejected packets loses frames at exactly those
/// two boundaries, which is what this class exists to prevent.
///
/// Every loop is bounded: cancellation is polled between steps and a
/// no-progress budget turns a source that neither accepts input nor produces
/// output into a reported failure instead of a spinning thread.
class VideoDecodePump {
public:
    enum class State {
        /// No packet held; the next input step reads one.
        Reading,
        /// A packet was read but the decoder rejected it; it must be resubmitted.
        PacketHeld,
        /// The drain request was sent; only receive can make progress now.
        Draining,
        /// Terminal states.
        Stopped,
        Failed,
    };

    enum class Outcome {
        /// A frame is in the source's frame slot.
        Frame,
        /// Cancellation was observed; no frame was produced.
        Cancelled,
        /// A step failed; `error` carries the reason.
        Failed,
    };

    struct Stats {
        uint64_t video_packets_read { 0 };
        uint64_t packets_accepted { 0 };
        /// Times a rejected packet was submitted again rather than dropped.
        uint64_t packets_resubmitted { 0 };
        uint64_t packets_released { 0 };
        uint64_t drain_requests { 0 };
        uint64_t loop_restarts { 0 };
        uint64_t frames_received { 0 };
        /// Steps that neither accepted input nor produced output.
        uint64_t stalled_steps { 0 };
    };

    /// `no_progress_budget` bounds consecutive steps that make no progress
    /// before the pump fails. It must be greater than zero.
    explicit VideoDecodePump(VideoDecodeSource& source, uint32_t no_progress_budget = 256);

    /// Runs the state machine until a frame is decoded, cancellation is
    /// observed, or a step fails.
    Outcome NextFrame(std::string* error);

    /// Re-arms the pump after the owner seeks the container itself. A held
    /// packet is released, because it belongs to the position that was left.
    void ResetForSeek();

    [[nodiscard]] State state() const noexcept { return m_state; }
    /// Whether the source still owns a packet the pump has not released.
    /// Tracked separately from the phase, so stopping or failing mid-packet
    /// cannot lose the one release that packet is owed.
    [[nodiscard]] bool holdsPacket() const noexcept { return m_packet_held; }
    [[nodiscard]] uint64_t loopIndex() const noexcept { return m_loop_index; }
    void setLoopIndex(uint64_t loop_index) noexcept { m_loop_index = loop_index; }
    [[nodiscard]] const Stats& stats() const noexcept { return m_stats; }

private:
    /// Runs one input step. Returns false once the pump has failed;
    /// `progressed` reports whether the step did any work.
    bool feed(bool* progressed, std::string* error);
    void fail(std::string message, std::string* error);
    void releaseHeldPacket();

    VideoDecodeSource& m_source;
    uint32_t           m_no_progress_budget;
    State              m_state { State::Reading };
    bool               m_packet_held { false };
    uint64_t           m_loop_index { 0 };
    uint32_t           m_no_progress_steps { 0 };
    Stats              m_stats {};
};

} // namespace wallpaper::video
