// Pins outputs that other code depends on bit for bit, so replacing the
// implementation behind them cannot move them unnoticed. The expected values
// were captured from the implementations this suite replaced; nothing here
// shells out or reads files.
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <thread>
#include <vector>

#include <gtest/gtest.h>

#include "Utils/Random.hpp"
#include "Utils/Sha.hpp"

namespace wallpaper
{
namespace
{
// WE_TEST_RANDOM_SEED seeds this engine, and the particle poster comparisons
// replay its sequence, so the same seed has to keep yielding the same values.
TEST(Random, SeededDoubleSequenceIsPinned) {
    Random::seed(12345u);
    const double expected[] = { 0x1.c7c25bcbdbf6ap-1, 0x1.0bb0440a87effp-3, 0x1.45b5b525e2a9bp-5,
                                0x1.a722a2fc68bc2p-1, 0x1.106c844522acep-1, 0x1.e9a1760330eb4p-1,
                                0x1.d90335c7dba9bp-2, 0x1.d8f4351d4e6d4p-1 };
    for (double value : expected) EXPECT_EQ(Random::get(0.0, 1.0), value);
}

TEST(Random, SeededFloatSequenceIsPinned) {
    Random::seed(12345u);
    const float expected[] = { 0x1.dee284p+7f, 0x1.d30be2p+7f, 0x1.26e9a4p+7f, 0x1.de6ca4p+6f,
                               0x1.fe59eep+6f, 0x1.a7db1p+6f,  0x1.055e3ap+7f, 0x1.bfee4ap+7f };
    for (float value : expected) EXPECT_EQ(Random::get(100.0f, 250.0f), value);
}

TEST(Random, SeededIntegerSequenceIsPinned) {
    Random::seed(12345u);
    const std::size_t small[] = { 2, 5, 1, 4, 9, 5, 2, 1, 6, 1, 9, 7 };
    for (std::size_t value : small) EXPECT_EQ(Random::get<std::size_t>(0, 9), value);

    Random::seed(12345u);
    const std::size_t wide[] = { 771445219, 601959910, 285080862, 561383554, 789925285, 170765738 };
    for (std::size_t value : wide) EXPECT_EQ(Random::get<std::size_t>(1, 1000000007ull), value);
}

TEST(Random, ReversedBoundsDrawFromTheSameRange) {
    Random::seed(12345u);
    const double reals[] = { 0x1.d30be1c972e28p+7, 0x1.de6ca3ef15d35p+6, 0x1.a7db0f048659fp+6,
                             0x1.bfee4b7fe55e4p+7 };
    for (double value : reals) EXPECT_EQ(Random::get(250.0, 100.0), value);

    Random::seed(12345u);
    const std::size_t ints[] = { 2, 5, 1, 4, 9, 5 };
    for (std::size_t value : ints) EXPECT_EQ(Random::get<std::size_t>(9, 0), value);
}

TEST(Random, EqualBoundsReturnThatValue) {
    EXPECT_EQ(Random::get(3.5, 3.5), 3.5);
    EXPECT_EQ(Random::get<std::size_t>(7, 7), std::size_t { 7 });
}

// Particle emission draws every type from one stream, so the order of mixed
// draws is part of the contract too.
TEST(Random, MixedDrawsShareOneStream) {
    Random::seed(4242u);
    const double      reals[]  = { 0x1.9dfcc3dca65fcp-1, 0x1.cfabda8ba7f1bp-2, 0x1.425a23ee4121cp-3,
                                   0x1.0743c6910f179p-1 };
    const float       floats[] = { 0x1.367762p+4f, 0x1.9baedap+3f, 0x1.09293p+4f, 0x1.ab46aep+3f };
    const std::size_t ints[]   = { 17, 17, 93, 42 };
    for (int i = 0; i < 4; ++i) {
        EXPECT_EQ(Random::get(0.0, 1.0), reals[i]);
        EXPECT_EQ(Random::get(10.0f, 20.0f), floats[i]);
        EXPECT_EQ(Random::get<std::size_t>(0, 99), ints[i]);
    }
}

TEST(Random, ReseedingRestartsTheSequence) {
    Random::seed(99u);
    std::vector<double> first;
    for (int i = 0; i < 5; ++i) first.push_back(Random::get(0.0, 1.0));
    Random::seed(99u);
    for (double value : first) EXPECT_EQ(Random::get(0.0, 1.0), value);
}

// The stream is per thread: seeding here must not disturb another thread, and
// that thread must not disturb this one.
TEST(Random, EachThreadOwnsItsStream) {
    Random::seed(7u);
    const double expected = Random::get(0.0, 1.0);
    Random::seed(7u);
    std::thread([] {
        Random::seed(1u);
        for (int i = 0; i < 100; ++i) Random::get(0.0, 1.0);
    }).join();
    EXPECT_EQ(Random::get(0.0, 1.0), expected);
}
} // namespace

namespace
{
std::string Digest(const std::string& bytes) { return utils::genSha1(std::span<const char>(bytes)); }

// Bytes 0..255 cycling in an order that is not a plain ramp, NULs included.
std::string Pattern(std::size_t size) {
    std::string bytes(size, '\0');
    for (std::size_t i = 0; i < size; ++i) bytes[i] = static_cast<char>((i * 131 + 7) & 0xff);
    return bytes;
}

// File names under the video cache and the in-memory shader and script cache
// keys come from this digest, so it has to stay the standard 40-character
// lowercase hex SHA-1 for the cached names to keep matching.
TEST(Sha1, MatchesTheFipsVectors) {
    EXPECT_EQ(Digest(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    EXPECT_EQ(Digest("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d");
    EXPECT_EQ(Digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
              "84983e441c3bd26ebaae4aa1f95129e5e54670f1");
    EXPECT_EQ(Digest(std::string(1000000, 'a')), "34aa973cd4c4daa4f61eeb2bdbad27316534016f");
}

// Captured from the digest this one replaced. The lengths straddle the padding
// edges (55/56, 63/64/65, 119/120) and the pattern carries NUL bytes.
TEST(Sha1, MatchesTheReplacedImplementationAcrossBlockEdges) {
    const struct {
        std::size_t size;
        const char* digest;
    } cases[] = {
        { 1, "5d1be7e9dda1ee8896be5b7e34a85ee16452a7b4" },
        { 55, "9e5a20c2604688df0b1eecf4474b58bfe7227881" },
        { 56, "bd367cf3b85dc2cac8f6b4827cb850e4c83c521c" },
        { 63, "a8f606c343b26fa851dfd149f7b12fc2dbf1af34" },
        { 64, "1abec92bfbde4197236cfba30b6b61c69d605d88" },
        { 65, "362ce7bc4bc2b47979741db349c65fd550840dc3" },
        { 119, "e7ceee9817914eef9ec7001a43033f16a086b7c7" },
        { 120, "9c9d46758300bc1f2c6953d4a2652ed72a202cf3" },
        { 128, "8abf03d87a20327b0a0dfbee98f04a881350d8f4" },
        { 1000, "425b5f2d2d344f4f6467cda9065cdc840619dc2d" },
        { 100003, "0d3f93f2dccadedcae5c5624cb456a4c8256d796" },
    };
    for (const auto& c : cases) {
        EXPECT_EQ(Digest(Pattern(c.size)), c.digest) << "size " << c.size;
        EXPECT_EQ(Digest(Pattern(c.size)).size(), utils::SHA1_LEN);
    }
}

TEST(Sha1, ASpanIsHashedByItsLengthNotItsFirstNul) {
    const std::string bytes("a\0b", 3);
    EXPECT_NE(Digest(bytes), Digest("a"));
    EXPECT_EQ(utils::genSha1(std::span<const char>(bytes.data(), 1)), Digest("a"));
}
} // namespace
} // namespace wallpaper
