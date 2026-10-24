#include "Fs/LimitedBinaryStream.h"
#include "Fs/MemBinaryStream.h"

#include <gtest/gtest.h>

#include <array>
#include <cstdint>
#include <memory>
#include <utility>
#include <vector>

TEST(LimitedBinaryStreamTest, RewindAndSeekEndSupportBeginningOfWindow) {
    std::vector<std::uint8_t> bytes{0xd1, 0x42, 0x07, 0xa6, 0x19, 0xf0, 0x5b, 0x82, 0x2e};
    auto source = std::make_shared<wallpaper::fs::MemBinaryStream>(std::move(bytes));
    ASSERT_TRUE(source->SeekSet(8));

    wallpaper::fs::LimitedBinaryStream window(source, 2, 5);
    EXPECT_EQ(window.Size(), 5);
    EXPECT_EQ(window.Tell(), 0);

    std::array<std::uint8_t, 8> buffer{0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc};
    ASSERT_EQ(window.Read(buffer.data() + 1, 6), 5U);
    const std::array<std::uint8_t, 8> full_window{0xcc, 0x07, 0xa6, 0x19,
                                                  0xf0, 0x5b, 0xcc, 0xcc};
    EXPECT_EQ(buffer, full_window);
    EXPECT_EQ(window.Tell(), 5);

    ASSERT_TRUE(window.Rewind());
    EXPECT_EQ(window.Tell(), 0);
    std::array<std::uint8_t, 3> replay{};
    ASSERT_EQ(window.Read(replay.data(), replay.size()), replay.size());
    const std::array<std::uint8_t, 3> window_prefix{0x07, 0xa6, 0x19};
    EXPECT_EQ(replay, window_prefix);
    EXPECT_EQ(window.Tell(), 3);

    ASSERT_TRUE(window.SeekEnd(0));
    EXPECT_EQ(window.Tell(), window.Size());
    std::array<std::uint8_t, 3> sentinel{0xb1, 0xc2, 0xd3};
    const auto untouched = sentinel;
    EXPECT_EQ(window.Read(sentinel.data(), sentinel.size()), 0U);
    EXPECT_EQ(sentinel, untouched);
    EXPECT_EQ(window.Tell(), 5);
}
