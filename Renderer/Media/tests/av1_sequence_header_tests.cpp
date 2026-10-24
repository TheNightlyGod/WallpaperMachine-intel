#include "Media/Av1/Av1SequenceHeader.hpp"

#include <gtest/gtest.h>

#include <string>
#include <vector>

namespace wallpaper::media
{
namespace
{

std::vector<std::uint8_t> FromHex(const std::string& hex)
{
    std::vector<std::uint8_t> bytes;
    for (std::size_t at = 0; at + 1 < hex.size(); at += 2) {
        bytes.push_back(static_cast<std::uint8_t>(std::stoul(hex.substr(at, 2), nullptr, 16)));
    }
    return bytes;
}

// Writes the fields of a sequence header the way the specification lists them.
class BitWriter {
public:
    void put(std::uint64_t value, int count)
    {
        for (int shift = count - 1; shift >= 0; --shift) {
            if (m_bits % 8 == 0) m_bytes.push_back(0);
            if (((value >> shift) & 1U) != 0) m_bytes.back() |= static_cast<std::uint8_t>(0x80U >> (m_bits % 8));
            ++m_bits;
        }
    }
    const std::vector<std::uint8_t>& bytes() const { return m_bytes; }

private:
    std::vector<std::uint8_t> m_bytes;
    std::size_t               m_bits { 0 };
};

std::vector<std::uint8_t> Obu(std::uint8_t type, const std::vector<std::uint8_t>& payload, bool extension = false)
{
    std::vector<std::uint8_t> out;
    out.push_back(static_cast<std::uint8_t>((type << 3) | (extension ? 0x04 : 0) | 0x02));
    if (extension) out.push_back(0);
    std::size_t size = payload.size();
    do {
        std::uint8_t byte = size & 0x7FU;
        size >>= 7;
        if (size != 0) byte |= 0x80U;
        out.push_back(byte);
    } while (size != 0);
    out.insert(out.end(), payload.begin(), payload.end());
    return out;
}

} // namespace

// The configOBUs of av1C records written by SVT-AV1 for 128x96 clips, one per
// range/colour setting.
TEST(Av1SequenceHeader, ReadsTheRangeOfRecordsAnEncoderWrote)
{
    struct Case {
        const char* hex;
        bool        full;
        int         depth;
        bool        described;
    };
    const Case cases[] = {
        { "0a0b0200000559bfdf00be0010", false, 8, false },   // limited range, nothing described
        { "0a0b0200000559bfdf00be0210", true, 8, false },    // full range
        { "0a0b0200000559bfdf00be1010", false, 10, false },  // 10-bit limited
        { "0a0b0200000559bfdf00be1210", true, 10, false },   // 10-bit full
        { "0a0e0200000559bfdf00be0408080610", true, 8, true },
        { "0a0e0200000559bfdf00be0408080410", false, 8, true },
    };
    for (const Case& test : cases) {
        const auto        obus = FromHex(test.hex);
        Av1SequenceColour colour;
        ASSERT_TRUE(ReadAv1SequenceColour(obus.data(), obus.size(), &colour)) << test.hex;
        EXPECT_EQ(colour.fullRange, test.full) << test.hex;
        EXPECT_EQ(colour.bitDepth, test.depth) << test.hex;
        EXPECT_EQ(colour.hasColourDescription, test.described) << test.hex;
        EXPECT_FALSE(colour.monochrome) << test.hex;
    }
}

TEST(Av1SequenceHeader, SkipsTimingDecoderModelAndOperatingPointFieldsBeforeTheColour)
{
    BitWriter w;
    w.put(0, 3);           // seq_profile
    w.put(0, 1);           // still_picture
    w.put(0, 1);           // reduced_still_picture_header
    w.put(1, 1);           // timing_info_present_flag
    w.put(1001, 32);       // num_units_in_display_tick
    w.put(60000, 32);      // time_scale
    w.put(1, 1);           // equal_picture_interval
    w.put(0b0001001, 7);   // uvlc: three leading zeros, a one, value bits 001
    w.put(1, 1);           // decoder_model_info_present_flag
    w.put(9, 5);           // buffer_delay_length_minus_1 (10 bits)
    w.put(1, 32);          // num_units_in_decoding_tick
    w.put(7, 5);           // buffer_removal_time_length_minus_1
    w.put(7, 5);           // frame_presentation_time_length_minus_1
    w.put(1, 1);           // initial_display_delay_present_flag
    w.put(1, 5);           // operating_points_cnt_minus_1: two points
    for (int point = 0; point < 2; ++point) {
        w.put(0, 12);                  // operating_point_idc
        w.put(point == 0 ? 8 : 4, 5);  // seq_level_idx (a tier bit follows above 7)
        if (point == 0) w.put(0, 1);   // seq_tier
        w.put(1, 1);                   // decoder_model_present_for_this_op
        w.put(5, 10);                  // decoder_buffer_delay
        w.put(5, 10);                  // encoder_buffer_delay
        w.put(0, 1);                   // low_delay_mode_flag
        w.put(1, 1);                   // initial_display_delay_present_for_this_op
        w.put(3, 4);                   // initial_display_delay_minus_1
    }
    w.put(10, 4);          // frame_width_bits_minus_1
    w.put(10, 4);          // frame_height_bits_minus_1
    w.put(1919, 11);       // max_frame_width_minus_1
    w.put(1079, 11);       // max_frame_height_minus_1
    w.put(1, 1);           // frame_id_numbers_present_flag
    w.put(5, 4);           // delta_frame_id_length_minus_2
    w.put(2, 3);           // additional_frame_id_length_minus_1
    w.put(0b101, 3);       // superblock, filter intra, edge filter
    w.put(0b1011, 4);      // interintra, masked, warped, dual filter
    w.put(1, 1);           // enable_order_hint
    w.put(0b11, 2);        // jnt_comp, ref_frame_mvs
    w.put(0, 1);           // seq_choose_screen_content_tools
    w.put(1, 1);           // seq_force_screen_content_tools
    w.put(0, 1);           // seq_choose_integer_mv
    w.put(0, 1);           // seq_force_integer_mv
    w.put(6, 3);           // order_hint_bits_minus_1
    w.put(0b010, 3);       // superres, cdef, restoration
    w.put(1, 1);           // high_bitdepth
    w.put(0, 1);           // mono_chrome
    w.put(1, 1);           // color_description_present_flag
    w.put(9, 8);           // BT.2020 primaries
    w.put(16, 8);          // PQ
    w.put(9, 8);           // BT.2020 non-constant matrix
    w.put(1, 1);           // color_range: full
    w.put(0b10, 2);        // chroma_sample_position-ish tail; never read

    const auto        obus = Obu(1, w.bytes());
    Av1SequenceColour colour;
    ASSERT_TRUE(ReadAv1SequenceColour(obus.data(), obus.size(), &colour));
    EXPECT_EQ(colour.bitDepth, 10);
    EXPECT_TRUE(colour.hasColourDescription);
    EXPECT_EQ(colour.primaries, 9);
    EXPECT_EQ(colour.transfer, 16);
    EXPECT_EQ(colour.matrix, 9);
    EXPECT_TRUE(colour.fullRange);
}

TEST(Av1SequenceHeader, SrgbImpliesFullRangeAndMonochromeStatesItsOwn)
{
    auto build = [](bool mono, bool srgb, bool range) {
        BitWriter w;
        w.put(0, 3);
        w.put(0, 1);
        w.put(1, 1);       // reduced_still_picture_header
        w.put(5, 5);       // seq_level_idx
        w.put(7, 4);
        w.put(7, 4);
        w.put(0, 8);       // width
        w.put(0, 8);       // height
        w.put(0b000, 3);   // superblock, filter intra, edge filter
        w.put(0b000, 3);   // superres, cdef, restoration
        w.put(0, 1);       // high_bitdepth
        w.put(mono ? 1 : 0, 1);
        w.put(1, 1);       // color_description_present_flag
        w.put(srgb ? 1 : 2, 8);
        w.put(srgb ? 13 : 2, 8);
        w.put(srgb ? 0 : 2, 8);
        if (! srgb || mono) w.put(range ? 1 : 0, 1);
        return Obu(1, w.bytes());
    };
    Av1SequenceColour colour;
    auto              srgb = build(false, true, false);
    ASSERT_TRUE(ReadAv1SequenceColour(srgb.data(), srgb.size(), &colour));
    EXPECT_TRUE(colour.fullRange) << "sRGB's range is implied, no bit follows";
    auto mono = build(true, false, true);
    ASSERT_TRUE(ReadAv1SequenceColour(mono.data(), mono.size(), &colour));
    EXPECT_TRUE(colour.monochrome);
    EXPECT_TRUE(colour.fullRange);
    auto plain = build(false, false, false);
    ASSERT_TRUE(ReadAv1SequenceColour(plain.data(), plain.size(), &colour));
    EXPECT_FALSE(colour.fullRange);
}

TEST(Av1SequenceHeader, FindsTheHeaderAfterOtherObusAndRefusesWhatIsNotOne)
{
    auto header = FromHex("0a0b0200000559bfdf00be0210");
    std::vector<std::uint8_t> stream = Obu(2, {});           // temporal delimiter
    const auto                padding = Obu(15, std::vector<std::uint8_t>(200, 0x55), true);
    stream.insert(stream.end(), padding.begin(), padding.end());
    stream.insert(stream.end(), header.begin(), header.end());
    Av1SequenceColour colour;
    ASSERT_TRUE(ReadAv1SequenceColour(stream.data(), stream.size(), &colour));
    EXPECT_TRUE(colour.fullRange);

    // No sequence header anywhere.
    const auto delimiter = Obu(2, {});
    EXPECT_FALSE(ReadAv1SequenceColour(delimiter.data(), delimiter.size(), &colour));
    EXPECT_FALSE(ReadAv1SequenceColour(nullptr, 0, &colour));
    // Cut off inside the header, inside the size field and with the forbidden bit set.
    for (std::size_t keep = 1; keep < header.size(); ++keep) {
        EXPECT_FALSE(ReadAv1SequenceColour(header.data(), keep, &colour)) << keep << " bytes";
    }
    const std::uint8_t forbidden[] = { 0x8A, 0x01, 0x00 };
    EXPECT_FALSE(ReadAv1SequenceColour(forbidden, sizeof forbidden, &colour));
}

} // namespace wallpaper::media
