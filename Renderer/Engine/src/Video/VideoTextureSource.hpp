#pragma once

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include "Video/VideoDisplayTransform.hpp"

namespace wallpaper
{
struct Image;

namespace video
{
struct VideoTextureFrame {
    uint32_t width { 0 };
    uint32_t height { 0 };
    void*    pixel_buffer { nullptr };
    void*    io_surface { nullptr };
    uint32_t pixel_format { 0 };
    uint32_t plane_count { 0 };
    double   pts_seconds { 0.0 };
    uint64_t generation { 0 };
    VideoDisplayTransform display_transform;

    uint32_t displayWidth() const { return display_transform.width != 0 ? display_transform.width : width; }
    uint32_t displayHeight() const { return display_transform.height != 0 ? display_transform.height : height; }
    bool needsDisplayTransform() const {
        return ! display_transform.identity() || displayWidth() != width || displayHeight() != height;
    }

    [[nodiscard]] bool valid() const
    {
        return (pixel_buffer != nullptr || io_surface != nullptr) && width > 0 && height > 0;
    }
};

struct VideoPlaybackState {
    bool   paused { false };
    float  rate { 1.0f };
    double scene_elapsed_seconds { 0.0 };
};

/// What a source is asked to play: the layer's own clock and controls under
/// the renderer's pause and rate. Every caller shares this one
/// definition, so none can disagree about what a global pause means.
inline VideoPlaybackState ResolveEffectiveVideoPlaybackState(const VideoPlaybackState& global_state,
                                                             const VideoPlaybackState& layer_state) {
    VideoPlaybackState effective_state = layer_state;
    effective_state.paused = global_state.paused || layer_state.paused;
    effective_state.rate = std::max(0.0f, global_state.rate) * std::max(0.0f, layer_state.rate);
    return effective_state;
}

/// What a source has actually done, as running totals.
///
/// This is source work, not consumer work: it may legitimately keep rising
/// while one consumer is hidden, provided another consumer still presents the
/// frames. Keeping it apart from the per-surface counters is what makes that
/// distinction readable instead of assumed.
struct VideoSourceStats {
    /// Process-unique identity of this decoder instance, assigned at
    /// construction. Two sources opened from the same file are two decoders and
    /// must never be folded into one: the identity is the running instance, not
    /// the path or a content hash. Zero means the source cannot identify
    /// itself, which reads as "not de-duplicable" rather than "shared".
    std::uint64_t instance_id { 0 };
    /// Frames the decoder produced and queued for display.
    std::uint64_t decoded_frames { 0 };
    /// Seeks and resyncs the decoder was asked to perform.
    std::uint64_t seek_requests { 0 };
    /// Shortest gap observed between decoded frames, or 0 when not yet proven.
    double        observed_period_seconds { 0.0 };
    /// How many usable gaps that observation is based on.
    std::uint64_t observed_samples { 0 };
};

class VideoTextureSource {
public:
    virtual ~VideoTextureSource() = default;

    virtual bool prime(std::string* error) = 0;
    virtual bool syncPlayback(const VideoPlaybackState& state, std::string* error) = 0;
    virtual bool refreshFrame(std::string* error) = 0;
    [[nodiscard]] virtual VideoTextureFrame currentFrame() const = 0;
    /// Like `currentFrame`, but takes an independent reference on the frame's
    /// platform objects so the caller can outlive the producer's own copy.
    ///
    /// This is what makes one decoder safe to read from several surfaces: the
    /// retain happens under the same lock that guards promotion, so a frame
    /// cannot be released between the read and the retain. The caller releases
    /// the result with `ReleaseAppleVideoFrame`. Returns false when no frame is
    /// available; sources that cannot retain report false and are simply never
    /// shared.
    [[nodiscard]] virtual bool retainCurrentFrame(VideoTextureFrame*) const { return false; }
    [[nodiscard]] virtual double durationSeconds() const = 0;
    [[nodiscard]] virtual double playbackSeconds() const = 0;
    [[nodiscard]] virtual uint64_t loopCount() const = 0;
    /// Seconds between this source's own frames, or 0 when it cannot say. The
    /// frame clock uses it to stop rendering more often than the content
    /// changes; an unknown period keeps the fixed cadence.
    [[nodiscard]] virtual double frameDurationSeconds() const = 0;
    /// Running totals of the work this source has done. Sources that cannot
    /// account for themselves report zeroes, which read as "not observable"
    /// rather than "no work".
    [[nodiscard]] virtual VideoSourceStats sourceStats() const { return {}; }
};

/// Opens a source on the media `image` describes: the file it names, or the
/// payload in its first mip.
///
/// A payload is shared, not copied: the source holds a reference on `image`
/// for as long as it still needs the bytes, so the caller may drop its own
/// reference, and a source that is held across a rebuild of the render graph
/// before anything has opened it still has what it was given. `image` must not
/// be modified while a source shares it.
std::shared_ptr<VideoTextureSource> CreateVideoTextureSource(std::shared_ptr<const Image> image,
                                                             std::string* error);

/// How many clocked sources have a decoder open right now: primed successfully
/// and not yet destroyed. A source holds its media and decoder for as long as it
/// lives, so this is what tells a video that was closed from one that was only
/// set aside, whichever decoder plays it.
[[nodiscard]] int OpenVideoDecoderCount();

/// Opens a source directly on a media file, without an `Image`. Needed when a
/// consumer is split off a shared session: by then the `Image` that started the
/// first decoder is gone.
std::shared_ptr<VideoTextureSource> CreateVideoTextureSourceForFile(std::string media_path, std::string* error);

} // namespace video
} // namespace wallpaper
