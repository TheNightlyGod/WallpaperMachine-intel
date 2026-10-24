#include "Media/Matroska/Vp9Header.hpp"

namespace wallpaper::media
{
namespace
{

// MSB-first bit reader; a read past the end latches `overrun`.
class BitReader {
public:
    BitReader(const std::uint8_t* data, std::size_t size) : m_data(data), m_size(size) {}

    std::uint32_t bits(int count)
    {
        std::uint32_t value = 0;
        for (int index = 0; index < count; ++index) {
            if (m_position >= m_size * 8) {
                m_overrun = true;
                return 0;
            }
            const std::uint32_t bit = (m_data[m_position >> 3] >> (7 - (m_position & 7))) & 1U;
            value                   = (value << 1) | bit;
            ++m_position;
        }
        return value;
    }
    bool overrun() const { return m_overrun; }

private:
    const std::uint8_t* m_data;
    std::size_t         m_size;
    std::size_t         m_position { 0 };
    bool                m_overrun { false };
};

constexpr std::uint32_t kCsRgb = 7;

bool ReadSyncCode(BitReader& reader)
{
    return reader.bits(8) == 0x49 && reader.bits(8) == 0x83 && reader.bits(8) == 0x42;
}

} // namespace

bool ParseVp9UncompressedHeader(const std::uint8_t* data, std::size_t size, Vp9FrameHeader* header, Error* error)
{
    BitReader      reader(data, size);
    Vp9FrameHeader out;
    auto truncated = [&]() { return Fail(error, ErrorKind::Truncated, "the VP9 frame header ends early"); };

    if (reader.bits(2) != 2) return reader.overrun() ? truncated() : Fail(error, ErrorKind::Corrupt, "bad VP9 frame marker");
    const std::uint32_t low  = reader.bits(1);
    const std::uint32_t high = reader.bits(1);
    out.profile              = static_cast<std::uint8_t>((high << 1) | low);
    if (out.profile == 3 && reader.bits(1) != 0) return Fail(error, ErrorKind::Corrupt, "reserved VP9 bit set");
    out.showExistingFrame = reader.bits(1) != 0;
    if (reader.overrun()) return truncated();
    if (out.showExistingFrame) {
        reader.bits(3);  // frame_to_show_map_idx
        if (reader.overrun()) return truncated();
        *header = out;
        return true;
    }
    out.keyFrame       = reader.bits(1) == 0;
    out.showFrame      = reader.bits(1) != 0;
    out.errorResilient = reader.bits(1) != 0;
    if (reader.overrun()) return truncated();

    auto colourConfig = [&]() {
        out.bitDepth = 8;
        if (out.profile >= 2) out.bitDepth = reader.bits(1) != 0 ? 12 : 10;
        out.colourSpace = static_cast<std::uint8_t>(reader.bits(3));
        if (out.colourSpace != kCsRgb) {
            out.fullRange    = reader.bits(1) != 0;
            out.subsamplingX = out.subsamplingY = 1;
            if (out.profile == 1 || out.profile == 3) {
                out.subsamplingX = static_cast<std::uint8_t>(reader.bits(1));
                out.subsamplingY = static_cast<std::uint8_t>(reader.bits(1));
                if (reader.bits(1) != 0) return false;  // reserved_zero
            }
        } else {
            out.fullRange = true;
            if (out.profile == 1 || out.profile == 3) {
                out.subsamplingX = out.subsamplingY = 0;
                if (reader.bits(1) != 0) return false;
            } else {
                return false;  // RGB needs profile 1 or 3
            }
        }
        out.hasColourConfig = true;
        return true;
    };
    auto frameSize = [&]() {
        out.width  = reader.bits(16) + 1;
        out.height = reader.bits(16) + 1;
    };

    if (out.keyFrame) {
        if (! ReadSyncCode(reader)) return reader.overrun() ? truncated() : Fail(error, ErrorKind::Corrupt, "bad VP9 sync code");
        if (! colourConfig()) return reader.overrun() ? truncated() : Fail(error, ErrorKind::Corrupt, "invalid VP9 colour configuration");
        frameSize();
    } else {
        out.intraOnly = out.showFrame ? false : reader.bits(1) != 0;
        if (! out.errorResilient) reader.bits(2);  // reset_frame_context
        if (out.intraOnly) {
            if (! ReadSyncCode(reader)) return reader.overrun() ? truncated() : Fail(error, ErrorKind::Corrupt, "bad VP9 sync code");
            if (out.profile > 0) {
                if (! colourConfig()) return reader.overrun() ? truncated() : Fail(error, ErrorKind::Corrupt, "invalid VP9 colour configuration");
            } else {
                out.bitDepth        = 8;
                out.colourSpace     = 1;  // BT.601
                out.subsamplingX    = out.subsamplingY = 1;
                out.hasColourConfig = true;
            }
            reader.bits(8);  // refresh_frame_flags
            frameSize();
        }
    }
    if (reader.overrun()) return truncated();
    *header = out;
    return true;
}

} // namespace wallpaper::media
