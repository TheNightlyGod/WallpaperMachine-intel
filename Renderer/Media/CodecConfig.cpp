#include "Media/CodecConfig.hpp"

#include "Media/ByteReader.hpp"

namespace wallpaper::media
{
namespace
{

bool AvcProfileHasChromaExtension(std::uint8_t profile)
{
    switch (profile) {
    case 100: case 110: case 122: case 144: case 244: case 44: case 83: case 86:
    case 118: case 128: case 138: case 139: case 134: case 135: return true;
    default: return false;
    }
}

bool SummarizeAvcC(const std::uint8_t* config, std::size_t size, std::uint8_t* bitDepth)
{
    ByteReader reader(config, size);
    reader.U8();  // configurationVersion
    const std::uint8_t profile = reader.U8();
    reader.Skip(2);  // profile compatibility, level
    reader.Skip(1);  // reserved + lengthSizeMinusOne
    const std::uint8_t spsCount = reader.U8() & 0x1FU;
    for (std::uint8_t index = 0; index < spsCount && reader.ok(); ++index) reader.Skip(reader.U16());
    const std::uint8_t ppsCount = reader.U8();
    for (std::uint8_t index = 0; index < ppsCount && reader.ok(); ++index) reader.Skip(reader.U16());
    if (! reader.ok()) return false;
    if (AvcProfileHasChromaExtension(profile) && reader.remaining() >= 3) {
        reader.U8();  // reserved + chroma_format
        const std::uint8_t luma = reader.U8() & 0x07U;
        *bitDepth = static_cast<std::uint8_t>(8 + luma);
    } else if (profile == 66 || profile == 77 || profile == 88 || profile == 100) {
        *bitDepth = 8;  // these profiles are 8-bit only
    }
    return true;
}

bool SummarizeHvcC(const std::uint8_t* config, std::size_t size, std::uint8_t* bitDepth)
{
    // The fixed part is 23 bytes; bitDepthLumaMinus8 is the low 3 bits of byte 17.
    if (size < 23) return false;
    *bitDepth = static_cast<std::uint8_t>(8 + (config[17] & 0x07U));
    return true;
}

bool SummarizeAv1C(const std::uint8_t* config, std::size_t size, std::uint8_t* bitDepth)
{
    if (size < 4 || config[0] != 0x81) return false;  // marker 1, version 1
    const bool high   = (config[2] & 0x40U) != 0;
    const bool twelve = (config[2] & 0x20U) != 0;
    *bitDepth = high ? (twelve ? 12 : 10) : 8;
    return true;
}

bool SummarizeVpcC(const std::uint8_t* config, std::size_t size, std::uint8_t* bitDepth,
                   ColourDescription* colour)
{
    if (size < 1) return false;
    if (config[0] != 1) return true;  // an older layout this reader does not interpret
    if (size < 12) return false;
    // FullBox header (4), profile, level, then bitDepth(4) chroma(3) fullRange(1).
    *bitDepth = static_cast<std::uint8_t>(config[6] >> 4);
    colour->source    = ColourDescription::Source::CodecConfig;
    colour->fullRange = (config[6] & 0x01U) != 0;
    colour->primaries = config[7];
    colour->transfer  = config[8];
    colour->matrix    = config[9];
    return true;
}

} // namespace

bool SummarizeCodecConfig(std::uint32_t configFourcc, const std::uint8_t* config, std::size_t size,
                          std::uint8_t* bitDepth, ColourDescription* colour)
{
    switch (configFourcc) {
    case FourCC('a', 'v', 'c', 'C'): return SummarizeAvcC(config, size, bitDepth);
    case FourCC('h', 'v', 'c', 'C'): return SummarizeHvcC(config, size, bitDepth);
    case FourCC('a', 'v', '1', 'C'): return SummarizeAv1C(config, size, bitDepth);
    case FourCC('v', 'p', 'c', 'C'): return SummarizeVpcC(config, size, bitDepth, colour);
    default: return true;
    }
}

} // namespace wallpaper::media
