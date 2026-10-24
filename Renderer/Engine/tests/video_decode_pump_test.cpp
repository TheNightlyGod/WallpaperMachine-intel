// Decoder state-machine regressions for the send/receive contract: a rejected
// input packet must be resubmitted rather than dropped, end of input must be
// drained before the stream restarts, and neither cancellation nor a source
// that makes no progress may leave the pump spinning.
#include "Video/VideoDecodePump.hpp"

#include <gtest/gtest.h>

#include <deque>
#include <string>
#include <vector>

namespace wallpaper::video
{
namespace
{

/// A scripted decoder. `packets` are the container's video packets; the decoder
/// holds `reorder_depth` of them before emitting the first frame, which is what
/// makes the delayed tail observable. `accept_every_other_send` reproduces a
/// decoder whose input queue is full and answers EAGAIN.
class ScriptedSource final : public VideoDecodeSource {
public:
    struct Options {
        int  packets_per_loop { 3 };
        int  reorder_depth { 0 };
        bool reject_first_send { false };
        bool reject_every_send { false };
        /// Raises cancellation the moment a send is rejected, so the pump stops
        /// while it is still holding that packet.
        bool cancel_on_send_reject { false };
        bool cancel_after_frames { false };
        int  cancel_frame_count { 0 };
        int  other_stream_packets { 0 };
    };

    explicit ScriptedSource(Options options) : m_options(options) { fill(); }

    DecodeStatus ReadPacket(std::string* /*error*/) override
    {
        EXPECT_FALSE(m_packet_held) << "the pump must not read over a held packet";
        // Packets of other streams are consumed here, exactly as a demuxer-backed
        // implementation does, and never surface to the pump.
        while (m_other_stream_remaining > 0) {
            --m_other_stream_remaining;
            ++other_stream_packets_released;
        }
        if (m_unread.empty()) return DecodeStatus::EndOfStream;
        m_packet = m_unread.front();
        m_unread.pop_front();
        m_packet_held = true;
        return DecodeStatus::Ok;
    }

    DecodeStatus SendPacket(std::string* /*error*/) override
    {
        EXPECT_TRUE(m_packet_held) << "send without a held packet";
        ++send_calls;
        if (m_options.reject_every_send ||
            (m_options.reject_first_send && !m_rejected_once)) {
            m_rejected_once = true;
            if (m_options.cancel_on_send_reject) m_cancelled = true;
            return DecodeStatus::Again;
        }
        m_queued.push_back(m_packet);
        return DecodeStatus::Ok;
    }

    void ReleasePacket() override
    {
        EXPECT_TRUE(m_packet_held) << "a packet was released twice";
        m_packet_held = false;
        released_packets.push_back(m_packet);
    }

    DecodeStatus SendDrainRequest(std::string* /*error*/) override
    {
        ++drain_requests;
        m_draining = true;
        return DecodeStatus::Ok;
    }

    DecodeStatus ReceiveFrame(std::string* /*error*/) override
    {
        const size_t hold = m_draining ? 0u : static_cast<size_t>(m_options.reorder_depth);
        if (m_queued.size() > hold) {
            received_frames.push_back(m_queued.front());
            m_queued.pop_front();
            if (m_options.cancel_after_frames &&
                received_frames.size() >= static_cast<size_t>(m_options.cancel_frame_count)) {
                m_cancelled = true;
            }
            return DecodeStatus::Ok;
        }
        if (m_draining && m_queued.empty()) return DecodeStatus::EndOfStream;
        return DecodeStatus::Again;
    }

    bool RestartAtStreamStart(std::string* /*error*/) override
    {
        ++restarts;
        m_draining = false;
        m_queued.clear();
        fill();
        return true;
    }

    [[nodiscard]] bool IsCancelled() const override { return m_cancelled; }

    void cancel() { m_cancelled = true; }

    int              send_calls { 0 };
    int              drain_requests { 0 };
    int              restarts { 0 };
    int              other_stream_packets_released { 0 };
    std::vector<int> released_packets;
    std::vector<int> received_frames;

private:
    void fill()
    {
        m_unread.clear();
        for (int index = 0; index < m_options.packets_per_loop; ++index) {
            m_unread.push_back(m_next_packet_id++);
        }
        m_other_stream_remaining = m_options.other_stream_packets;
    }

    Options         m_options;
    std::deque<int> m_unread;
    std::deque<int> m_queued;
    int             m_packet { -1 };
    int             m_next_packet_id { 1 };
    int             m_other_stream_remaining { 0 };
    bool            m_packet_held { false };
    bool            m_draining { false };
    bool            m_rejected_once { false };
    bool            m_cancelled { false };
};

/// A source that never accepts input and never produces output.
class StalledSource final : public VideoDecodeSource {
public:
    DecodeStatus ReadPacket(std::string* /*error*/) override { return DecodeStatus::Again; }
    DecodeStatus SendPacket(std::string* /*error*/) override { return DecodeStatus::Again; }
    void ReleasePacket() override { ++releases; }
    DecodeStatus SendDrainRequest(std::string* /*error*/) override { return DecodeStatus::Ok; }
    DecodeStatus ReceiveFrame(std::string* /*error*/) override { return DecodeStatus::Again; }
    bool RestartAtStreamStart(std::string* error) override
    {
        if (error != nullptr) *error = "restart should not be reached";
        return false;
    }
    [[nodiscard]] bool IsCancelled() const override { return false; }

    int releases { 0 };
};

/// A source whose seek fails, so the loop boundary cannot be completed.
class UnseekableSource final : public VideoDecodeSource {
public:
    DecodeStatus ReadPacket(std::string* /*error*/) override { return DecodeStatus::EndOfStream; }
    DecodeStatus SendPacket(std::string* /*error*/) override { return DecodeStatus::Ok; }
    void ReleasePacket() override {}
    DecodeStatus SendDrainRequest(std::string* /*error*/) override { return DecodeStatus::Ok; }
    DecodeStatus ReceiveFrame(std::string* /*error*/) override { return DecodeStatus::EndOfStream; }
    bool RestartAtStreamStart(std::string* error) override
    {
        if (error != nullptr) *error = "seek failed";
        return false;
    }
    [[nodiscard]] bool IsCancelled() const override { return false; }
};

std::vector<int> DecodeFrames(VideoDecodePump& pump, int count)
{
    std::vector<int> outcomes;
    for (int index = 0; index < count; ++index) {
        std::string error;
        const auto outcome = pump.NextFrame(&error);
        EXPECT_EQ(outcome, VideoDecodePump::Outcome::Frame) << error;
        if (outcome != VideoDecodePump::Outcome::Frame) break;
        outcomes.push_back(static_cast<int>(pump.loopIndex()));
    }
    return outcomes;
}

/// The decode order this project used before the pump existed: read a packet,
/// submit it, release it unconditionally, and on end of input seek straight
/// back to the start. Reproduced here so the fixtures below are known to
/// distinguish the two orders instead of passing for either one.
VideoDecodePump::Outcome LegacyDecodeNextFrame(ScriptedSource& source)
{
    while (true) {
        std::string error;
        const DecodeStatus read = source.ReadPacket(&error);
        if (read == DecodeStatus::EndOfStream) {
            // Flush and seek with delayed output still inside the decoder.
            if (!source.RestartAtStreamStart(&error)) return VideoDecodePump::Outcome::Failed;
            continue;
        }
        if (read == DecodeStatus::Error) return VideoDecodePump::Outcome::Failed;
        if (read == DecodeStatus::Again) continue;

        const DecodeStatus sent = source.SendPacket(&error);
        source.ReleasePacket();  // released even when the decoder refused it
        if (sent == DecodeStatus::Error) return VideoDecodePump::Outcome::Failed;

        while (true) {
            const DecodeStatus received = source.ReceiveFrame(&error);
            if (received == DecodeStatus::Again) break;
            if (received == DecodeStatus::EndOfStream) {
                if (!source.RestartAtStreamStart(&error)) return VideoDecodePump::Outcome::Failed;
                break;
            }
            if (received == DecodeStatus::Error) return VideoDecodePump::Outcome::Failed;
            return VideoDecodePump::Outcome::Frame;
        }
    }
}

TEST(VideoDecodePump, TheLegacyFeedFirstOrderDropsTheRejectedPacket)
{
    ScriptedSource source({ .packets_per_loop = 3, .reorder_depth = 0, .reject_first_send = true });

    ASSERT_EQ(LegacyDecodeNextFrame(source), VideoDecodePump::Outcome::Frame);
    EXPECT_EQ(source.received_frames, std::vector<int> { 2 })
        << "the rejected first packet is gone: its frame never reaches output";
    EXPECT_EQ(source.released_packets, (std::vector<int> { 1, 2 }))
        << "the refused packet was released as if it had been consumed";
}

TEST(VideoDecodePump, TheLegacyEndOfInputSeekLosesTheReorderedTail)
{
    ScriptedSource source({ .packets_per_loop = 4, .reorder_depth = 2 });

    for (int index = 0; index < 4; ++index) {
        ASSERT_EQ(LegacyDecodeNextFrame(source), VideoDecodePump::Outcome::Frame) << index;
    }
    // Two packets were still inside the decoder when the stream was rewound.
    EXPECT_EQ(source.received_frames, (std::vector<int> { 1, 2, 5, 6 }))
        << "packets 3 and 4 were discarded by the flush at end of input";
    EXPECT_EQ(source.drain_requests, 0) << "the legacy order never asked the decoder to drain";
}

TEST(VideoDecodePump, RejectedPacketIsResubmittedAndReleasedExactlyOnce)
{
    ScriptedSource source({ .packets_per_loop = 3, .reorder_depth = 0, .reject_first_send = true });
    VideoDecodePump pump(source);

    std::string error;
    ASSERT_EQ(pump.NextFrame(&error), VideoDecodePump::Outcome::Frame) << error;

    // The rejected packet is the one that came back: dropping it on EAGAIN is
    // what loses a frame, and releasing it twice is a use-after-free.
    EXPECT_EQ(source.received_frames, std::vector<int> { 1 });
    EXPECT_EQ(source.released_packets, std::vector<int> { 1 });
    EXPECT_EQ(source.send_calls, 2);
    EXPECT_EQ(pump.stats().packets_resubmitted, 1u);
    EXPECT_EQ(pump.stats().packets_released, 1u);
}

TEST(VideoDecodePump, DelayedFramesAreDrainedBeforeTheStreamRestarts)
{
    // Two packets are held back by reordering, so a restart that skips the
    // drain request loses the last two frames of every loop.
    ScriptedSource source({ .packets_per_loop = 4, .reorder_depth = 2 });
    VideoDecodePump pump(source);

    const auto loops = DecodeFrames(pump, 8);
    ASSERT_EQ(loops.size(), 8u);
    EXPECT_EQ(source.received_frames, (std::vector<int> { 1, 2, 3, 4, 5, 6, 7, 8 }))
        << "every packet of both loops must reach output";
    EXPECT_EQ(loops, (std::vector<int> { 0, 0, 0, 0, 1, 1, 1, 1 }))
        << "the loop index advances once, at the drained end of the stream";
    EXPECT_EQ(source.drain_requests, 2);
    EXPECT_EQ(source.restarts, 1);
    EXPECT_EQ(pump.stats().loop_restarts, 1u);
}

TEST(VideoDecodePump, DrainRequestIsSentOnceAtEachEndOfInput)
{
    ScriptedSource source({ .packets_per_loop = 2, .reorder_depth = 1 });
    VideoDecodePump pump(source);

    DecodeFrames(pump, 2);
    EXPECT_EQ(source.drain_requests, 1) << "one null packet per end of input";
    EXPECT_EQ(source.restarts, 0) << "the restart waits for decoder end of stream";

    // The third frame crosses the loop boundary: the decoder reports end of
    // stream, the stream restarts, and no second null packet is sent for the
    // same end of input.
    DecodeFrames(pump, 1);
    EXPECT_EQ(source.restarts, 1);
    EXPECT_EQ(source.drain_requests, 1);

    // Only reaching the next end of input earns the next drain request.
    DecodeFrames(pump, 1);
    EXPECT_EQ(source.drain_requests, 2);
    EXPECT_EQ(source.restarts, 1);
}

TEST(VideoDecodePump, PacketsOfOtherStreamsNeverReachTheDecoder)
{
    ScriptedSource source({ .packets_per_loop = 2, .other_stream_packets = 3 });
    VideoDecodePump pump(source);

    DecodeFrames(pump, 2);
    EXPECT_EQ(source.other_stream_packets_released, 3);
    EXPECT_EQ(source.send_calls, 2) << "only video packets are submitted";
    EXPECT_EQ(pump.stats().video_packets_read, 2u);
}

TEST(VideoDecodePump, CancellationStopsTheLoopWithoutAFrameOrAnError)
{
    ScriptedSource source({ .packets_per_loop = 4 });
    VideoDecodePump pump(source);
    DecodeFrames(pump, 1);

    source.cancel();
    std::string error;
    EXPECT_EQ(pump.NextFrame(&error), VideoDecodePump::Outcome::Cancelled);
    EXPECT_TRUE(error.empty()) << "cancellation is not a failure";
    EXPECT_EQ(pump.state(), VideoDecodePump::State::Stopped);
}

TEST(VideoDecodePump, CancellationDuringDrainIsObservedImmediately)
{
    // Cancellation raised while delayed frames are still being drained must be
    // seen on the next step rather than after the loop completes.
    ScriptedSource source({ .packets_per_loop = 3,
                            .reorder_depth = 2,
                            .cancel_after_frames = true,
                            .cancel_frame_count = 1 });
    VideoDecodePump pump(source);

    std::string error;
    ASSERT_EQ(pump.NextFrame(&error), VideoDecodePump::Outcome::Frame) << error;
    EXPECT_EQ(pump.NextFrame(&error), VideoDecodePump::Outcome::Cancelled);
    EXPECT_EQ(source.restarts, 0);
}

TEST(VideoDecodePump, ASourceThatMakesNoProgressFailsWithinItsBudget)
{
    StalledSource source;
    VideoDecodePump pump(source, 8);

    std::string error;
    EXPECT_EQ(pump.NextFrame(&error), VideoDecodePump::Outcome::Failed);
    EXPECT_FALSE(error.empty());
    EXPECT_EQ(pump.state(), VideoDecodePump::State::Failed);
    EXPECT_EQ(pump.stats().stalled_steps, 8u);
    EXPECT_EQ(source.releases, 0) << "a packet that was never accepted is not released";

    // A failed pump stays failed instead of restarting the same stall.
    EXPECT_EQ(pump.NextFrame(&error), VideoDecodePump::Outcome::Failed);
    EXPECT_EQ(pump.stats().stalled_steps, 8u);
}

TEST(VideoDecodePump, AFailedRestartIsReportedInsteadOfLooping)
{
    UnseekableSource source;
    VideoDecodePump pump(source, 4);

    std::string error;
    EXPECT_EQ(pump.NextFrame(&error), VideoDecodePump::Outcome::Failed);
    EXPECT_EQ(error, "seek failed");
    EXPECT_EQ(pump.loopIndex(), 0u) << "a failed restart does not advance the loop";
}

TEST(VideoDecodePump, ResetForSeekReleasesAHeldPacketExactlyOnce)
{
    // Cancellation lands while the rejected packet is still held. That packet
    // belongs to the position the owner is seeking away from, so the reset owes
    // it exactly one release — no leak, no double free.
    ScriptedSource source({ .packets_per_loop = 3,
                            .reject_first_send = true,
                            .cancel_on_send_reject = true });
    VideoDecodePump pump(source);

    std::string error;
    ASSERT_EQ(pump.NextFrame(&error), VideoDecodePump::Outcome::Cancelled);
    ASSERT_TRUE(pump.holdsPacket()) << "stopping must not lose the packet's release";

    pump.ResetForSeek();
    pump.ResetForSeek();
    EXPECT_FALSE(pump.holdsPacket());
    EXPECT_EQ(source.released_packets, std::vector<int> { 1 });
    EXPECT_EQ(pump.state(), VideoDecodePump::State::Reading);
}

TEST(VideoDecodePump, FailingWhileHoldingAPacketStillReleasesIt)
{
    // A decoder that never accepts input must not leave the pump terminal with
    // a packet the owner can no longer reach.
    ScriptedSource source({ .packets_per_loop = 2, .reject_every_send = true });
    VideoDecodePump pump(source, 4);

    std::string error;
    EXPECT_EQ(pump.NextFrame(&error), VideoDecodePump::Outcome::Failed);
    EXPECT_FALSE(error.empty());
    EXPECT_FALSE(pump.holdsPacket());
    EXPECT_EQ(source.released_packets, std::vector<int> { 1 });
    EXPECT_EQ(pump.stats().packets_released, 1u);
    EXPECT_GE(pump.stats().packets_resubmitted, 3u);
}

TEST(VideoDecodePump, SeekResetKeepsTheOwnersLoopIndex)
{
    ScriptedSource source({ .packets_per_loop = 2, .reorder_depth = 1 });
    VideoDecodePump pump(source);

    pump.setLoopIndex(7);
    pump.ResetForSeek();
    DecodeFrames(pump, 2);
    EXPECT_EQ(pump.loopIndex(), 7u);
    DecodeFrames(pump, 1);
    EXPECT_EQ(pump.loopIndex(), 8u) << "the next loop continues from the seeked position";
}

} // namespace
} // namespace wallpaper::video
