// The shared foundation of the container readers: error reporting, checked
// arithmetic, exact fractions and the bounds-checked byte cursor.
#include "Media/ByteReader.hpp"
#include "Media/Checked.hpp"
#include "Media/Error.hpp"
#include "Media/Rational.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <limits>
#include <vector>

namespace wallpaper::media
{
namespace
{

TEST(MediaError, FailFillsTheErrorAndReturnsFalse)
{
    Error error;
    EXPECT_FALSE(error);
    EXPECT_FALSE(Fail(&error, ErrorKind::Truncated, "moov box exceeds the file", 42));
    EXPECT_TRUE(error);
    EXPECT_EQ(error.kind, ErrorKind::Truncated);
    EXPECT_EQ(Describe(error), "truncated at offset 42: moov box exceeds the file");
}

TEST(MediaError, FailAcceptsANullErrorSink)
{
    EXPECT_FALSE(Fail(nullptr, ErrorKind::Corrupt, "ignored"));
}

TEST(MediaError, DescribeOmitsWhatIsNotKnown)
{
    Error error;
    error.kind = ErrorKind::Unsupported;
    EXPECT_EQ(Describe(error), "unsupported");
    error.message = "codec V_VP8";
    EXPECT_EQ(Describe(error), "unsupported: codec V_VP8");
}

TEST(MediaChecked, ArithmeticReportsOverflowInsteadOfWrapping)
{
    std::uint32_t narrow = 0;
    EXPECT_TRUE(CheckedAdd<std::uint32_t>(4000000000U, 200000000U, &narrow));
    EXPECT_EQ(narrow, 4200000000U);
    EXPECT_FALSE(CheckedAdd<std::uint32_t>(4000000000U, 300000000U, &narrow));

    std::uint64_t wide = 0;
    EXPECT_FALSE(CheckedSub<std::uint64_t>(1, 2, &wide));
    EXPECT_TRUE(CheckedSub<std::uint64_t>(2, 1, &wide));
    EXPECT_EQ(wide, 1U);
    EXPECT_FALSE(CheckedMul<std::uint64_t>(std::uint64_t { 1 } << 40, std::uint64_t { 1 } << 30, &wide));
    EXPECT_TRUE(CheckedMul<std::uint64_t>(std::uint64_t { 1 } << 30, std::uint64_t { 1 } << 30, &wide));
    EXPECT_EQ(wide, std::uint64_t { 1 } << 60);
}

TEST(MediaChecked, RescaleRoundsToNearestWithoutOverflowingTheProduct)
{
    std::int64_t out = 0;
    // 90 kHz ticks to nanoseconds: 3003 ticks of 1/90000 s.
    ASSERT_TRUE(RescaleRound(3003, 1000000000, 90000, &out));
    EXPECT_EQ(out, 33366667);
    // Ties go away from zero in both directions.
    ASSERT_TRUE(RescaleRound(1, 1, 2, &out));
    EXPECT_EQ(out, 1);
    ASSERT_TRUE(RescaleRound(-1, 1, 2, &out));
    EXPECT_EQ(out, -1);
    // value * numerator overflows 64 bits, the quotient does not.
    constexpr std::int64_t big = std::int64_t { 1 } << 62;
    ASSERT_TRUE(RescaleRound(big, 8, 16, &out));
    EXPECT_EQ(out, big / 2);
    // The quotient itself does not fit.
    EXPECT_FALSE(RescaleRound(big, 8, 1, &out));
    EXPECT_FALSE(RescaleRound(1, 1, 0, &out));
    EXPECT_FALSE(RescaleRound(1, 1, -5, &out));
}

TEST(MediaRational, ReducesAndNormalisesTheSign)
{
    const Rational period = MakeRational(2002, 60000);
    EXPECT_EQ(period.numerator, 1001);
    EXPECT_EQ(period.denominator, 30000);
    const Rational negative = MakeRational(3, -6);
    EXPECT_EQ(negative.numerator, -1);
    EXPECT_EQ(negative.denominator, 2);
    const Rational zero = MakeRational(0, 25);
    EXPECT_EQ(zero.numerator, 0);
    EXPECT_EQ(zero.denominator, 1);
}

TEST(MediaRational, ADenominatorOfZeroIsUnknownNotAFraction)
{
    EXPECT_FALSE(MakeRational(1, 0).valid());
    EXPECT_FALSE(MakeRational(std::numeric_limits<std::int64_t>::min(), 1).valid());
    EXPECT_EQ(MakeRational(1, 0).toDouble(), 0.0);
}

TEST(MediaRational, ComparesExactlyWhereDoublesWouldTie)
{
    const Rational a = MakeRational(1001, 30000);
    const Rational b = MakeRational(1, 30);
    EXPECT_GT(CompareRational(a, b), 0);
    EXPECT_LT(CompareRational(b, a), 0);
    EXPECT_EQ(CompareRational(a, MakeRational(2002, 60000)), 0);
    EXPECT_TRUE(a == MakeRational(2002, 60000));
    EXPECT_TRUE(a != b);
    // Products near 2^126 must not overflow.
    const Rational huge = MakeRational(std::numeric_limits<std::int64_t>::max(), 3);
    const Rational slightly = MakeRational(std::numeric_limits<std::int64_t>::max() - 1, 3);
    EXPECT_GT(CompareRational(huge, slightly), 0);
}

TEST(MediaByteReader, ReadsBigEndianIntegersInOrder)
{
    const std::vector<std::uint8_t> bytes { 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
                                            0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0xFF, 0xFE };
    ByteReader reader(bytes.data(), bytes.size());
    EXPECT_EQ(reader.U8(), 0x01U);
    EXPECT_EQ(reader.U16(), 0x0203U);
    EXPECT_EQ(reader.U24(), 0x040506U);
    EXPECT_EQ(reader.U32(), 0x0708090AU);
    EXPECT_EQ(reader.position(), 10U);
    EXPECT_EQ(reader.Unsigned(5), 0x0B0C0D0E0FU);
    EXPECT_EQ(reader.I16(), static_cast<std::int16_t>(0xFFFE));
    EXPECT_TRUE(reader.ok());
    EXPECT_TRUE(reader.atEnd());
}

TEST(MediaByteReader, ASixtyFourBitReadAndSignedWidths)
{
    const std::vector<std::uint8_t> bytes { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, 0x80, 0x00, 0x00, 0x00 };
    ByteReader reader(bytes.data(), bytes.size());
    EXPECT_EQ(reader.I64(), -2);
    EXPECT_EQ(reader.I32(), std::numeric_limits<std::int32_t>::min());
    EXPECT_TRUE(reader.ok());
}

TEST(MediaByteReader, AReadPastTheEndLatchesFailureAndConsumesNothing)
{
    const std::vector<std::uint8_t> bytes { 0xAA, 0xBB, 0xCC };
    ByteReader reader(bytes.data(), bytes.size());
    EXPECT_EQ(reader.U32(), 0U);
    EXPECT_FALSE(reader.ok());
    // Even a read that would now fit stays failed: one test at the end is enough.
    EXPECT_EQ(reader.U8(), 0U);
    EXPECT_FALSE(reader.ok());
    EXPECT_EQ(reader.position(), 0U);
}

TEST(MediaByteReader, SkipTakeAndSubStayInsideTheBuffer)
{
    const std::vector<std::uint8_t> bytes { 1, 2, 3, 4, 5, 6 };
    ByteReader reader(bytes.data(), bytes.size());
    ASSERT_TRUE(reader.Skip(1));
    ByteReader sub = reader.Sub(3);
    EXPECT_TRUE(reader.ok());
    EXPECT_EQ(sub.size(), 3U);
    EXPECT_EQ(sub.U8(), 2U);
    EXPECT_EQ(sub.U16(), 0x0304U);
    EXPECT_EQ(sub.U8(), 0U);  // the sub-reader cannot read into its parent's remainder
    EXPECT_FALSE(sub.ok());
    EXPECT_TRUE(reader.ok());
    EXPECT_EQ(reader.U8(), 5U);

    const std::uint8_t* taken = reader.Take(1);
    ASSERT_NE(taken, nullptr);
    EXPECT_EQ(*taken, 6U);
    EXPECT_EQ(reader.Take(1), nullptr);
    EXPECT_FALSE(reader.ok());
}

TEST(MediaByteReader, OversizedSubAndSkipFailInsteadOfWrapping)
{
    const std::vector<std::uint8_t> bytes { 1, 2, 3 };
    ByteReader reader(bytes.data(), bytes.size());
    EXPECT_FALSE(reader.Skip(std::numeric_limits<std::size_t>::max()));
    EXPECT_FALSE(reader.ok());

    ByteReader other(bytes.data(), bytes.size());
    ByteReader sub = other.Sub(std::numeric_limits<std::size_t>::max());
    EXPECT_FALSE(sub.ok());
    EXPECT_EQ(sub.size(), 0U);
    EXPECT_FALSE(other.ok());

    ByteReader wide(bytes.data(), bytes.size());
    EXPECT_EQ(wide.Unsigned(9), 0U);
    EXPECT_FALSE(wide.ok());
}

TEST(MediaByteReader, AnEmptyReaderIsUsableAndFailsOnTheFirstRead)
{
    ByteReader reader;
    EXPECT_TRUE(reader.ok());
    EXPECT_TRUE(reader.atEnd());
    EXPECT_EQ(reader.U8(), 0U);
    EXPECT_FALSE(reader.ok());
}

} // namespace
} // namespace wallpaper::media
