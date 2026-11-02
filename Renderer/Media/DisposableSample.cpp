#include "Media/DisposableSample.hpp"

namespace wallpaper::media
{
namespace
{

enum class Verdict { Keep, Neutral, Disposable };

/// H.264 (ITU-T H.264 7.3.1): one byte, `forbidden_zero_bit`, `nal_ref_idc` (2),
/// `nal_unit_type` (5).
Verdict H264Unit(const std::uint8_t* unit, std::size_t size)
{
    if (size < 1) return Verdict::Keep;
    const unsigned refIdc = (unit[0] >> 5) & 3U;
    const unsigned type   = unit[0] & 0x1FU;
    switch (type) {
    case 1: // a slice of a non-IDR picture
    case 2: // slice data partitions A, B, C
    case 3:
    case 4:
        return refIdc == 0 ? Verdict::Disposable : Verdict::Keep;
    case 6:  // SEI
    case 9:  // access unit delimiter
    case 12: // filler data
        return Verdict::Neutral;
    default: // IDR slices, parameter sets, end of sequence or stream, extensions
        return Verdict::Keep;
    }
}

/// HEVC (ITU-T H.265 7.3.1.2): two bytes, `forbidden_zero_bit`, `nal_unit_type`
/// (6), `nuh_layer_id` (6), `nuh_temporal_id_plus1` (3).
Verdict HevcUnit(const std::uint8_t* unit, std::size_t size, unsigned highestTemporalId)
{
    if (size < 2) return Verdict::Keep;
    const unsigned type       = (unit[0] >> 1) & 0x3FU;
    const unsigned layer      = ((unit[0] & 1U) << 5) | (unit[1] >> 3);
    const unsigned temporalId = (unit[1] & 7U) - 1U;
    if (type < 16) {
        // Even types below 16 are the sub-layer non-reference pictures. Only on
        // the highest sub-layer is "non-reference" true of every later picture.
        const bool nonReference = (type % 2) == 0;
        return nonReference && layer == 0 && (unit[1] & 7U) != 0 && temporalId == highestTemporalId
            ? Verdict::Disposable
            : Verdict::Keep;
    }
    switch (type) {
    case 35: // access unit delimiter
    case 38: // filler data
    case 39: // prefix SEI
    case 40: // suffix SEI
        return Verdict::Neutral;
    default: // IRAP pictures, parameter sets, end of sequence or bitstream, reserved
        return Verdict::Keep;
    }
}

} // namespace

bool IsDisposableSample(const VideoStreamInfo& info, const std::uint8_t* data, std::size_t size)
{
    if (data == nullptr || size == 0) return false;
    const auto& record = info.codecConfig;
    const bool  h264   = info.configFourcc == FourCC('a', 'v', 'c', 'C');
    const bool  hevc   = info.configFourcc == FourCC('h', 'v', 'c', 'C');
    std::size_t lengthSize        = 0;
    unsigned    highestTemporalId = 0;
    if (h264) {
        // AVCDecoderConfigurationRecord: lengthSizeMinusOne in the low bits of byte 4.
        if (record.size() < 5) return false;
        lengthSize = (record[4] & 3U) + 1U;
    } else if (hevc) {
        // HEVCDecoderConfigurationRecord byte 21: constantFrameRate (2),
        // numTemporalLayers (3), temporalIdNested (1), lengthSizeMinusOne (2).
        if (record.size() < 23) return false;
        const unsigned temporalLayers = (record[21] >> 3) & 7U;
        if (temporalLayers == 0) return false; // not stated
        highestTemporalId = temporalLayers - 1U;
        lengthSize        = (record[21] & 3U) + 1U;
    } else {
        return false;
    }
    if (lengthSize == 3) return false; // not a length size either format allows

    bool        slice = false;
    std::size_t at    = 0;
    while (at < size) {
        if (size - at < lengthSize) return false;
        std::size_t length = 0;
        for (std::size_t index = 0; index < lengthSize; ++index) length = (length << 8) | data[at + index];
        at += lengthSize;
        if (length == 0 || length > size - at) return false;
        const Verdict verdict = h264 ? H264Unit(data + at, length) : HevcUnit(data + at, length, highestTemporalId);
        if (verdict == Verdict::Keep) return false;
        if (verdict == Verdict::Disposable) slice = true;
        at += length;
    }
    return slice;
}

} // namespace wallpaper::media
