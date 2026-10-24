// What a container reader reports about a video track, in terms every reader
// shares so one adapter can turn either into decoder input: the codec and its
// raw configuration record, the picture's size and orientation, its colour
// description, its timing, and one entry per compressed sample.
#pragma once

#include "Media/DisplayMatrix.hpp"
#include "Media/Rational.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace wallpaper::media
{

constexpr std::uint32_t FourCC(char a, char b, char c, char d)
{
    return (static_cast<std::uint32_t>(static_cast<std::uint8_t>(a)) << 24) |
           (static_cast<std::uint32_t>(static_cast<std::uint8_t>(b)) << 16) |
           (static_cast<std::uint32_t>(static_cast<std::uint8_t>(c)) << 8) |
           static_cast<std::uint32_t>(static_cast<std::uint8_t>(d));
}

/// "avc1"; unprintable bytes become '?'.
std::string FourCCString(std::uint32_t code);

/// ITU-T H.273 colour codes (the numbers `colr`/`nclx`, `vpcC` and Matroska's
/// Colour element share). 2 means "unspecified" in all three code tables.
struct ColourDescription {
    enum class Source : std::uint8_t {
        None,
        /// An ISO-BMFF `colr` box of type `nclx`: primaries, transfer, matrix, range.
        ContainerNclx,
        /// A QuickTime `colr` box of type `nclc`: three codes, range not stated
        /// (video range).
        ContainerNclc,
        /// The codec configuration record (`vpcC`, `av1C`) said so.
        CodecConfig,
        /// A Matroska Colour element.
        Matroska,
    };

    Source        source { Source::None };
    std::uint16_t primaries { 2 };
    std::uint16_t transfer { 2 };
    std::uint16_t matrix { 2 };
    bool          fullRange { false };

    bool present() const { return source != Source::None; }
};

struct VideoStreamInfo {
    /// The sample entry type for ISO-BMFF ('avc1', 'hvc1', 'av01', 'vp09' ...);
    /// readers of other containers map their codec id to the same code.
    std::uint32_t codecFourcc { 0 };
    /// The type of the configuration record in `codecConfig` ('avcC', 'hvcC',
    /// 'av1C', 'vpcC'), or 0 when there is none.
    std::uint32_t configFourcc { 0 };
    /// That record's bytes exactly as stored (an ISO-BMFF box's payload, without
    /// the 8-byte header), ready to hand to a decoder as a format-description atom.
    std::vector<std::uint8_t> codecConfig;

    /// The size of the coded picture.
    std::uint32_t codedWidth { 0 };
    std::uint32_t codedHeight { 0 };
    /// The track's presentation size before the display matrix is applied; 0 when
    /// the container does not say (use the coded size).
    std::uint32_t displayWidth { 0 };
    std::uint32_t displayHeight { 0 };
    DisplayMatrix displayMatrix { kIdentityDisplayMatrix };
    /// Pixel aspect ratio from `pasp` (horizontal : vertical); invalid when absent.
    Rational pixelAspect;

    ColourDescription colour;
    /// Bits per luma sample if the codec configuration says, else 0.
    std::uint8_t bitDepth { 0 };

    /// Ticks per second of every time below and of each Sample's dts, pts and
    /// duration. Always positive after a successful open.
    std::int64_t timescale { 0 };
    /// How long the track plays, in ticks: the edit list's total when there is
    /// one, else the header's duration, else the end of the last sample.
    std::int64_t durationTicks { 0 };
    /// The end of the last sample (largest pts + duration), from the sample table.
    std::int64_t contentEndTicks { 0 };
    /// Shortest and mean sample duration in seconds as exact fractions; invalid
    /// when the container carries no durations. Frame-pacing evidence.
    Rational minFramePeriod;
    Rational avgFramePeriod;

    std::uint32_t trackId { 0 };
};

/// One compressed sample (a video frame) located in the input. Times are in
/// `VideoStreamInfo::timescale` ticks and already include the edit list: a
/// negative `pts` is a sample that plays before the edit begins (pre-roll that a
/// player decodes but does not show). Samples are in decode order.
struct Sample {
    std::uint64_t offset { 0 };
    std::int64_t  dts { 0 };
    std::int64_t  pts { 0 };
    /// Ticks the frame is shown for; 0 when the container does not say.
    std::int64_t  duration { 0 };
    std::uint32_t size { 0 };
    bool          sync { false };
};

} // namespace wallpaper::media
