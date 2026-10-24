// Turns what a container reader reports about a video track into what
// VideoToolbox needs to decode it: a CMVideoFormatDescription carrying the
// codec's configuration record, the colour description, and the pixel format
// the decoded frames should arrive in. This is the Apple side of the
// container readers: ObjC++ over Core Media, written from Apple's headers and
// the codec bindings (ISO/IEC 14496-15, the AV1 and VP9 ISO-BMFF bindings).
//
// The interface is plain C++ so the scene engine's C++ sources can include it;
// Core Foundation objects are held as opaque pointers.
#pragma once

#include "Media/Matroska/Vp9Header.hpp"
#include "Media/VideoTypes.hpp"

#include <cstddef>
#include <cstdint>
#include <string>

namespace wallpaper::media::apple
{

/// Every refusal this layer makes starts with this, so a caller can tell "this
/// Mac cannot decode it" from "the file is damaged".
inline constexpr const char* kFormatNotSupported = "format not supported: ";

/// Chroma layout as the codec's configuration record states it.
enum class ChromaSubsampling : std::uint8_t { Unknown, Yuv420, Yuv422, Yuv444, Monochrome };

/// The chroma layout of the stream, from its configuration record (or, for VP9
/// in WebM, from the first key frame's header). `Unknown` when it says nothing,
/// which callers treat as 4:2:0.
ChromaSubsampling ChromaSubsamplingOf(const VideoStreamInfo& info, const Vp9FrameHeader* vp9);

/// An owned CMVideoFormatDescriptionRef. Move only.
class FormatDescription {
public:
    FormatDescription() = default;
    /// Adopts one retained reference.
    explicit FormatDescription(void* retained) : m_ref(retained) {}
    FormatDescription(FormatDescription&& other) noexcept : m_ref(other.m_ref) { other.m_ref = nullptr; }
    FormatDescription& operator=(FormatDescription&& other) noexcept;
    FormatDescription(const FormatDescription&) = delete;
    FormatDescription& operator=(const FormatDescription&) = delete;
    ~FormatDescription();

    void* get() const { return m_ref; }
    explicit operator bool() const { return m_ref != nullptr; }

private:
    void* m_ref { nullptr };
};

struct StreamFormat {
    FormatDescription description;
    /// The CMVideoCodecType ('avc1', 'hvc1', 'av01', 'vp09').
    std::uint32_t codecType { 0 };
    /// The CVPixelFormatType the decoder is asked to produce: biplanar 4:2:0, 8-bit
    /// ('420v', '420f') or 10-bit ('x420', 'xf20').
    std::uint32_t pixelFormat { 0 };
    std::uint8_t  bitDepth { 8 };
    bool          fullRange { false };
};

/// Builds the decoder input description for `info`. `vp9` is the first key
/// frame's header for a VP9 stream read from WebM (there is no `vpcC` there);
/// `firstSample` is the first sync sample's bytes, scanned for parameter sets
/// when the configuration record carries none (H.264 `avc3`, HEVC `hev1`), and
/// may be empty.
///
/// Returns false and sets `*whyNot` when the stream cannot be decoded: a codec
/// this Mac has no decoder for (VP8, AV1 without hardware decode), 4:2:2 or
/// 4:4:4 chroma, a bit depth other than 8 and 10, or a record too short to use.
/// Refusals for a format begin with `kFormatNotSupported`.
bool MakeStreamFormat(const VideoStreamInfo& info, const Vp9FrameHeader* vp9, const std::uint8_t* firstSample,
                      std::size_t firstSampleSize, StreamFormat* out, std::string* whyNot);

} // namespace wallpaper::media::apple
