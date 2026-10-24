#include "Media/Av1/Av1SequenceHeader.hpp"

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
    bool flag() { return bits(1) != 0; }
    void skip(int count)
    {
        // Skips up to 32 bits at a time so a long field cannot overflow bits().
        while (count > 0 && ! m_overrun) {
            const int step = count > 32 ? 32 : count;
            bits(step);
            count -= step;
        }
    }
    /// uvlc(): leading zeros, a one, then that many value bits.
    void skipUvlc()
    {
        int zeros = 0;
        while (! m_overrun && ! flag()) {
            if (++zeros >= 32) return;
        }
        skip(zeros);
    }
    bool overrun() const { return m_overrun; }

private:
    const std::uint8_t* m_data;
    std::size_t         m_size;
    std::size_t         m_position { 0 };
    bool                m_overrun { false };
};

constexpr std::uint8_t kObuSequenceHeader = 1;

bool ReadSequenceHeader(const std::uint8_t* payload, std::size_t size, Av1SequenceColour* out)
{
    BitReader        reader(payload, size);
    Av1SequenceColour colour;
    colour.profile = static_cast<std::uint8_t>(reader.bits(3));
    reader.bits(1);  // still_picture
    const bool reduced = reader.flag();
    if (reduced) {
        reader.bits(5);  // seq_level_idx[0]
    } else {
        bool       decoderModel = false;
        int        delayLength  = 0;
        const bool timing       = reader.flag();
        if (timing) {
            reader.skip(32);  // num_units_in_display_tick
            reader.skip(32);  // time_scale
            if (reader.flag()) reader.skipUvlc();  // equal_picture_interval: num_ticks_per_picture_minus_1
            decoderModel = reader.flag();
            if (decoderModel) {
                delayLength = static_cast<int>(reader.bits(5)) + 1;  // buffer_delay_length_minus_1
                reader.skip(32);                                    // num_units_in_decoding_tick
                reader.bits(5);                                     // buffer_removal_time_length_minus_1
                reader.bits(5);                                     // frame_presentation_time_length_minus_1
            }
        }
        const bool displayDelay = reader.flag();
        const unsigned count    = reader.bits(5) + 1;
        for (unsigned index = 0; index < count && ! reader.overrun(); ++index) {
            reader.bits(12);  // operating_point_idc
            const std::uint32_t level = reader.bits(5);
            if (level > 7) reader.bits(1);  // seq_tier
            if (decoderModel && reader.flag()) {
                reader.skip(delayLength);  // decoder_buffer_delay
                reader.skip(delayLength);  // encoder_buffer_delay
                reader.bits(1);            // low_delay_mode_flag
            }
            if (displayDelay && reader.flag()) reader.bits(4);  // initial_display_delay_minus_1
        }
    }
    const int widthBits  = static_cast<int>(reader.bits(4)) + 1;
    const int heightBits = static_cast<int>(reader.bits(4)) + 1;
    reader.skip(widthBits);   // max_frame_width_minus_1
    reader.skip(heightBits);  // max_frame_height_minus_1
    if (! reduced && reader.flag()) {  // frame_id_numbers_present_flag
        reader.bits(4);                // delta_frame_id_length_minus_2
        reader.bits(3);                // additional_frame_id_length_minus_1
    }
    reader.bits(3);  // use_128x128_superblock, enable_filter_intra, enable_intra_edge_filter
    if (! reduced) {
        reader.bits(4);  // enable_interintra_compound, masked_compound, warped_motion, dual_filter
        const bool orderHint = reader.flag();
        if (orderHint) reader.bits(2);  // enable_jnt_comp, enable_ref_frame_mvs
        std::uint32_t forceScreenContent = 2;  // SELECT_SCREEN_CONTENT_TOOLS
        if (! reader.flag()) forceScreenContent = reader.bits(1);  // seq_choose_screen_content_tools
        if (forceScreenContent > 0) {
            if (! reader.flag()) reader.bits(1);  // seq_choose_integer_mv, seq_force_integer_mv
        }
        if (orderHint) reader.bits(3);  // order_hint_bits_minus_1
    }
    reader.bits(3);  // enable_superres, enable_cdef, enable_restoration

    // color_config()
    const bool high = reader.flag();
    if (colour.profile == 2 && high) {
        colour.bitDepth = reader.flag() ? 12 : 10;
    } else {
        colour.bitDepth = high ? 10 : 8;
    }
    colour.monochrome = colour.profile == 1 ? false : reader.flag();
    colour.hasColourDescription = reader.flag();
    if (colour.hasColourDescription) {
        colour.primaries = static_cast<std::uint8_t>(reader.bits(8));
        colour.transfer  = static_cast<std::uint8_t>(reader.bits(8));
        colour.matrix    = static_cast<std::uint8_t>(reader.bits(8));
    }
    if (colour.monochrome) {
        colour.fullRange = reader.flag();
    } else if (colour.primaries == 1 && colour.transfer == 13 && colour.matrix == 0) {
        colour.fullRange = true;  // sRGB: the range is implied
    } else {
        colour.fullRange = reader.flag();
    }
    if (reader.overrun()) return false;
    *out = colour;
    return true;
}

} // namespace

bool ReadAv1SequenceColour(const std::uint8_t* obus, std::size_t size, Av1SequenceColour* colour)
{
    if (obus == nullptr || colour == nullptr) return false;
    std::size_t at = 0;
    while (at < size) {
        const std::uint8_t header = obus[at++];
        if ((header & 0x80U) != 0) return false;  // forbidden bit
        const std::uint8_t type = (header >> 3) & 0x0FU;
        if ((header & 0x04U) != 0) {              // extension byte
            if (at >= size) return false;
            ++at;
        }
        std::size_t length = 0;
        if ((header & 0x02U) != 0) {              // has_size_field: leb128
            unsigned shift = 0;
            for (;;) {
                if (at >= size || shift > 28) return false;
                const std::uint8_t byte = obus[at++];
                length |= static_cast<std::size_t>(byte & 0x7FU) << shift;
                shift += 7;
                if ((byte & 0x80U) == 0) break;
            }
        } else {
            length = size - at;  // the OBU runs to the end of the data
        }
        if (length > size - at) return false;
        if (type == kObuSequenceHeader) return ReadSequenceHeader(obus + at, length, colour);
        at += length;
    }
    return false;
}

} // namespace wallpaper::media
