#pragma once

#include "Video/VideoTextureSource.hpp"

#include <cstdint>
#include <string>

namespace wallpaper::video
{

/// What produces decoded frames for a `ClockedVideoSource`: a container reader
/// and a decoder behind one small interface. The source owns the clock, the
/// frame queue, seek policy and pacing; a backend only opens a stream and hands
/// over the next frame in presentation order, looping at the end.
///
/// A backend is driven by one thread at a time (the source's decode thread,
/// after `open`), except `cancel`, which any thread may call and which must make
/// a blocked `open` or `decodeNext` return promptly.
class VideoFrameBackend {
public:
    /// Facts the source needs about the stream, valid after `open`.
    struct StreamInfo {
        /// Length of one pass in seconds; 0 when the container does not say.
        double duration_seconds { 0.0 };
        /// The frame period the source assumes until it has seen real
        /// timestamps (1/60 s when the container has no rate).
        double frame_duration_seconds { 1.0 / 60.0 };
        /// Shortest period the container's declared rates imply, 0 when none. It
        /// seeds the pacing estimator as an upper bound and never unlocks pacing
        /// on its own.
        double shortest_declared_period_seconds { 0.0 };
    };

    enum class Decode {
        /// A frame is waiting; `takeFrame` or `discardFrame` must follow.
        Frame,
        /// `cancel` was observed. Not an error.
        Cancelled,
        Failed,
    };

    /// Where the frame `decodeNext` produced sits in the stream.
    struct DecodedPosition {
        /// Presentation time within its pass.
        double   pts_seconds { 0.0 };
        /// Which pass: 0 for the first, one more each time the stream restarts.
        uint64_t loop_index { 0 };
    };

    virtual ~VideoFrameBackend() = default;

    /// Opens the media and the decoder. May block; `cancel` aborts it.
    virtual bool open(std::string* error) = 0;
    [[nodiscard]] virtual StreamInfo streamInfo() const = 0;

    /// Decodes the next frame in presentation order, restarting at the head of
    /// the stream after the last frame. `fallback_pts_seconds` stands in for a
    /// frame whose timestamp the container lost.
    virtual Decode decodeNext(double fallback_pts_seconds, DecodedPosition* position,
                              std::string* error) = 0;
    /// Moves the decoded frame into `out` (an owned reference the caller
    /// releases) with its display transform set.
    virtual bool takeFrame(VideoTextureFrame* out, std::string* error) = 0;
    /// Drops the frame `decodeNext` produced.
    virtual void discardFrame() = 0;

    /// Repositions so the next `decodeNext` returns a frame at or before
    /// `wrapped_seconds` of pass `loop_index`, as near as the stream's keyframes
    /// allow. Anything decoded before it is dropped.
    virtual bool seek(double wrapped_seconds, uint64_t loop_index, std::string* error) = 0;
    /// Pass the next frame belongs to.
    [[nodiscard]] virtual uint64_t loopIndex() const = 0;

    /// Thread-safe cooperative cancellation. Latched.
    virtual void cancel() = 0;
    /// Releases the decoder and the media. Called once, after the decode thread
    /// has stopped.
    virtual void close() = 0;
};

} // namespace wallpaper::video
