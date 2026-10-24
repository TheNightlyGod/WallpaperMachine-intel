#pragma once

#include "Video/VideoFrameBackend.hpp"

#include <memory>
#include <string>

namespace wallpaper
{
struct Image;

namespace video
{

/// Plays MP4/QuickTime and WebM/Matroska video with the project's own container
/// readers (Renderer/Media) and VideoToolbox. An embedded payload is read where
/// it lies instead of being written out for a demuxer.
///
/// The decoder is a `VTDecompressionSession` driven by `VideoDecodePump`; frames
/// arrive in display order as IOSurface-backed NV12 (or 'x420' for 10-bit)
/// buffers. A seek restarts decoding at the sync sample at or before the target;
/// looping restarts at the first one.
class NativeVideoBackend final : public VideoFrameBackend {
public:
    /// Shares `image` (see `CreateVideoTextureSource`). A file-backed image is read
    /// in place. An embedded payload is read from memory when it is small, and
    /// otherwise moved into an anonymous file the moment the backend opens, so the
    /// image's buffer can go and a long video does not stay resident in the process.
    explicit NativeVideoBackend(std::shared_ptr<const Image> image);
    /// Opens a media file directly, without an `Image`.
    explicit NativeVideoBackend(std::string media_path);
    ~NativeVideoBackend() override;

    bool open(std::string* error) override;
    [[nodiscard]] StreamInfo streamInfo() const override;
    Decode decodeNext(double fallback_pts_seconds, DecodedPosition* position, std::string* error) override;
    bool takeFrame(VideoTextureFrame* out, std::string* error) override;
    void discardFrame() override;
    bool seek(double wrapped_seconds, uint64_t loop_index, std::string* error) override;
    [[nodiscard]] uint64_t loopIndex() const override;
    void cancel() override;
    void close() override;

private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

/// Bytes above which an embedded payload is moved out of memory into an anonymous
/// file when a backend opens (default 8 MiB; `WALLPAPER_MACHINE_VIDEO_SPILL_BYTES`
/// overrides it, for tests and for measuring).
[[nodiscard]] uint64_t NativeVideoPayloadSpillBytes();

} // namespace video
} // namespace wallpaper
