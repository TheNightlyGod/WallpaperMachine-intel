// Synthetic H.264 media for tests that need a real decodable file.
//
// Encoding is the slow part, so one group of pictures is encoded once per test
// binary and written out as many times as a given size needs. Tests that want
// media of their own get it from here rather than shipping a fixture.
//
// This header is plain C++ so the `.cpp` tests can include it; the encoder
// (VideoToolbox) and the writer (AVAssetWriter, passthrough) live in
// `synthetic_video.mm`. Nothing here depends on FFmpeg: a file this writes is
// what the decoders under test are shown, so the fixture must not share a
// library with the thing being tested.

#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>

namespace wallpaper::video
{
namespace testing_media
{

constexpr int kFrameWidth  = 640;
constexpr int kFrameHeight = 360;
constexpr int kGopFrames   = 30;

/// The luma the encoder was given for pixel (x, y) of frame `index` of the group
/// of pictures: noise that differs from frame to frame, so that a picture can be
/// matched back to the frame it came from.
inline uint8_t FrameLuma(int index, int x, int y) {
    return static_cast<uint8_t>(
        (static_cast<uint32_t>(x * 131 + y * 17 + index * 7919) * 2654435761u) >> 13);
}

/// Frames of the long clip, which is one group of pictures: twenty seconds with a
/// keyframe at the start only, so that seeking to a late frame decodes every
/// frame before it, which takes a good deal longer than a draw.
constexpr int kLongGopFrames = 600;
constexpr int kBarWidth      = 8;

/// The left column of the bar that frame `index` of the long clip carries: it
/// crosses the picture once, so the column tells the frame.
inline int LongGopBarColumn(int index) {
    return index * (kFrameWidth - kBarWidth) / (kLongGopFrames - 1);
}

/// The frame of the long clip whose bar has its left column at `column`.
inline int LongGopFrameOfColumn(int column) {
    return column * (kLongGopFrames - 1) / (kFrameWidth - kBarWidth);
}

/// Whether a VideoToolbox H.264 encoder produced the shared group of pictures.
/// Tests that need media assert this first, so a machine without an encoder
/// says so instead of failing on a missing file. The group is encoded on the
/// first call and reused for every later one.
bool EncoderAvailable();

/// Keyframes the encoder put in the long clip. `WriteLongGopVideo` refuses
/// anything but one; this is the number it checked.
int LongGopKeyframes();

/// Writes a decodable MP4 holding `repeats` copies of the shared group of
/// pictures: 640x360 at 30 per second, each frame a luma plane over neutral
/// chroma, the first frame a keyframe, no B-frames.
///
/// `salt` goes into a container metadata tag so two files with the same frame
/// count still differ byte for byte, which keeps one test's extraction cache
/// entry out of another's way.
///
/// `display_matrix`, when given, is the 3x3 matrix of the track header in the
/// layout the container stores it: nine 16.16 fixed-point values, row by row,
/// with the last one 2.30. Only the 2x2 part (a, b, c, d) is written.
///
/// The picture carries no colour tags: a decoder has to infer the matrix from
/// the picture size, and the tests' absolute colours rely on that.
bool WriteSyntheticVideo(const std::filesystem::path& path, int repeats, const std::string& salt,
                         std::optional<std::array<int32_t, 9>> display_matrix = std::nullopt);

/// Frames of the reordered clip: two groups of 30 pictures with B-frames.
constexpr int kReorderedFrames = 60;

/// Writes the reordered clip: 640x360 at 30 per second, `kReorderedFrames`
/// frames, a keyframe at 0 and at 30, frame `i` carrying the luma
/// `FrameLuma(i, x, y)` and shown at `i / 30` seconds, but with B-frames, so the
/// order the samples are stored in is not the order they are shown in. False
/// when there is no encoder, or it produced no reordering at all.
bool WriteReorderedVideo(const std::filesystem::path& path, const std::string& salt);

/// Writes the long clip: twenty seconds, one keyframe. False when there is no
/// encoder, and when the encoder cut the group of pictures short, which would
/// leave a seek no longer than any other.
bool WriteLongGopVideo(const std::filesystem::path& path, const std::string& salt);

/// What a 10-bit clip says its code values mean: colour primaries, transfer
/// function and matrix, as a stream declares them.
enum class TenBitTagging {
    /// BT.2020 primaries and matrix, SMPTE ST 2084 (perceptual quantizer).
    Pq,
    /// BT.2020 primaries and matrix, BT.2100 hybrid log-gamma.
    Hlg,
    /// BT.709 primaries, transfer and matrix: display-referred 10-bit SDR.
    Bt709,
};

/// The 10-bit code values of a clip's one flat colour, as the encoder is given
/// them: studio range, so luma runs 64 to 940 and chroma 64 to 960 around 512.
struct TenBitPicture {
    uint16_t y { 64 };
    uint16_t cb { 512 };
    uint16_t cr { 512 };
};

/// Frames of a 10-bit clip.
constexpr int kTenBitFrames = 12;

/// Whether VideoToolbox can encode HEVC Main10 here. 10-bit tests assert this
/// first, so a machine without that encoder says so instead of failing on a
/// missing file. Tried on the first call and remembered.
bool TenBitEncoderAvailable();

/// Writes a decodable MP4 of `kTenBitFrames` frames of HEVC Main10, 640x360 at 30
/// per second, every frame the flat colour `picture` and the first one a
/// keyframe, with no B-frames. The tagging is written into both the bitstream
/// and the container, so a reader that trusts either one sees it.
///
/// `max_content_light_nits`, when positive, is attached to the pictures as the
/// content light level, which an encoder that carries it writes out as the
/// stream's own statement of its peak.
bool WriteTenBitVideo(const std::filesystem::path& path, TenBitTagging tagging, TenBitPicture picture,
                      const std::string& salt, int max_content_light_nits = 0);

} // namespace testing_media
} // namespace wallpaper::video
