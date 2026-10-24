#include "Video/VideoDecodePump.hpp"

#include <utility>

namespace wallpaper::video
{

VideoDecodePump::VideoDecodePump(VideoDecodeSource& source, uint32_t no_progress_budget)
    : m_source(source)
    , m_no_progress_budget(no_progress_budget > 0 ? no_progress_budget : 1)
{
}

void VideoDecodePump::fail(std::string message, std::string* error)
{
    // Failing while a rejected packet is still held would leak it: the owner
    // has no way to reach it once the pump is terminal.
    releaseHeldPacket();
    m_state = State::Failed;
    if (error != nullptr) *error = std::move(message);
}

void VideoDecodePump::releaseHeldPacket()
{
    if (!m_packet_held) return;
    m_packet_held = false;
    m_source.ReleasePacket();
    ++m_stats.packets_released;
}

void VideoDecodePump::ResetForSeek()
{
    releaseHeldPacket();
    if (m_state != State::Failed) m_state = State::Reading;
    m_no_progress_steps = 0;
}

VideoDecodePump::Outcome VideoDecodePump::NextFrame(std::string* error)
{
    if (m_state == State::Failed) return Outcome::Failed;

    while (true) {
        if (m_source.IsCancelled()) {
            m_state = State::Stopped;
            return Outcome::Cancelled;
        }

        // Receive first: the decoder accepts new input only once its output has
        // been taken, and a fully drained decoder is the only proof that the
        // current loop really ended.
        std::string receive_error;
        const DecodeStatus received = m_source.ReceiveFrame(&receive_error);
        if (received == DecodeStatus::Ok) {
            ++m_stats.frames_received;
            m_no_progress_steps = 0;
            return Outcome::Frame;
        }
        if (received == DecodeStatus::Error) {
            fail(std::move(receive_error), error);
            return Outcome::Failed;
        }
        if (received == DecodeStatus::EndOfStream) {
            // Delayed output is exhausted, so the loop is complete. Only now
            // may the decoder be flushed and the container rewound; doing it at
            // end of input instead discards the reordered tail frames.
            std::string restart_error;
            if (!m_source.RestartAtStreamStart(&restart_error)) {
                fail(std::move(restart_error), error);
                return Outcome::Failed;
            }
            ++m_loop_index;
            ++m_stats.loop_restarts;
            m_state = State::Reading;
            m_no_progress_steps = 0;
            continue;
        }

        bool progressed = false;
        if (!feed(&progressed, error)) return Outcome::Failed;
        if (progressed) {
            m_no_progress_steps = 0;
            continue;
        }

        ++m_stats.stalled_steps;
        if (++m_no_progress_steps >= m_no_progress_budget) {
            fail("video decoder made no progress within its budget", error);
            return Outcome::Failed;
        }
    }
}

bool VideoDecodePump::feed(bool* progressed, std::string* error)
{
    *progressed = false;

    // While draining, the decoder takes no further input: only receiving the
    // delayed frames above can move the state machine on. A drain that yields
    // neither a frame nor end of stream is counted, not retried forever.
    if (m_state == State::Draining) return true;

    if (m_state == State::Reading) {
        std::string read_error;
        switch (m_source.ReadPacket(&read_error)) {
        case DecodeStatus::Ok:
            ++m_stats.video_packets_read;
            m_packet_held = true;
            m_state = State::PacketHeld;
            *progressed = true;
            return true;
        case DecodeStatus::EndOfStream: {
            // Exactly one drain request per end of input: the Draining state is
            // what keeps a second null packet out.
            std::string drain_error;
            if (m_source.SendDrainRequest(&drain_error) == DecodeStatus::Error) {
                fail(std::move(drain_error), error);
                return false;
            }
            ++m_stats.drain_requests;
            m_state = State::Draining;
            *progressed = true;
            return true;
        }
        case DecodeStatus::Again:
            return true;
        case DecodeStatus::Error:
            fail(std::move(read_error), error);
            return false;
        }
        return true;
    }

    std::string send_error;
    switch (m_source.SendPacket(&send_error)) {
    case DecodeStatus::Ok:
        ++m_stats.packets_accepted;
        releaseHeldPacket();
        m_state = State::Reading;
        *progressed = true;
        return true;
    case DecodeStatus::Again:
        // The decoder did not consume the packet. Keep holding it — releasing
        // it here is exactly what drops a frame — and resubmit it after the
        // next receive has made room.
        ++m_stats.packets_resubmitted;
        return true;
    case DecodeStatus::EndOfStream:
        // A flushed decoder will not accept input again: give up the packet we
        // still own and drain whatever is left.
        releaseHeldPacket();
        m_state = State::Draining;
        *progressed = true;
        return true;
    case DecodeStatus::Error:
        // fail() releases the packet this state still owns.
        fail(std::move(send_error), error);
        return false;
    }
    return true;
}

} // namespace wallpaper::video
