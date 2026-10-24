#include <cstdint>
#include <span>
#include <vector>

#include <gtest/gtest.h>

#include "Scene/Parse/ImageOrientation.hpp"

TEST(ImageOrientation, AllEightDisplayTransformsPreserveRGBA) {
    const std::vector<std::vector<int>> expected = {
        {1,2,3,4,5,6}, {3,2,1,6,5,4}, {6,5,4,3,2,1}, {4,5,6,1,2,3},
        {1,4,2,5,3,6}, {4,1,5,2,6,3}, {6,3,5,2,4,1}, {3,6,2,5,1,4}};
    for (int orientation = 1; orientation <= 8; ++orientation) {
        std::vector<uint8_t> pixels;
        for (int i = 1; i <= 6; ++i) pixels.insert(pixels.end(), {uint8_t(i), 17, 29, 131});
        int w = 3, h = 2;
        wallpaper::OrientRGBA(pixels.data(), w, h, orientation);
        EXPECT_EQ(w, orientation >= 5 ? 2 : 3);
        EXPECT_EQ(h, orientation >= 5 ? 3 : 2);
        for (int i = 0; i < 6; ++i) {
            EXPECT_EQ(pixels[i*4], expected[orientation-1][i]);
            EXPECT_EQ(pixels[i*4+1], 17);
            EXPECT_EQ(pixels[i*4+2], 29);
            EXPECT_EQ(pixels[i*4+3], 131);
        }
    }
}

TEST(ImageOrientation, ExifByteOrdersAndTruncation) {
    for (bool le : {false, true}) for (int orientation = 1; orientation <= 8; ++orientation) {
        std::vector<uint8_t> b = {0xff,0xd8,0xff,0xe1,0,34,'E','x','i','f',0,0};
        auto u16 = [&](unsigned v) {
            b.push_back(le ? v & 255 : v >> 8); b.push_back(le ? v >> 8 : v & 255);
        };
        auto u32 = [&](unsigned v) { if (le) {u16(v & 65535); u16(v >> 16);}
                                    else {u16(v >> 16); u16(v & 65535);} };
        b.push_back(le ? 'I' : 'M'); b.push_back(le ? 'I' : 'M');
        u16(42); u32(8); u16(1); u16(0x112); u16(3); u32(1); u16(orientation); u16(0); u32(0);
        EXPECT_EQ(wallpaper::JpegOrientation(b), orientation);
        for (size_t n = 0; n < b.size(); ++n)
            EXPECT_EQ(wallpaper::JpegOrientation(std::span(b).first(n)), 1);
        b[16] = b[17] = b[18] = b[19] = 255; // Invalid IFD offset.
        EXPECT_EQ(wallpaper::JpegOrientation(b), 1);
    }
}
