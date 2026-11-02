// IsDisposableSample: which pictures a late player may leave undecoded. Samples
// are built from NAL unit headers by hand; the bytes after a header are never read.
#include "Media/DisposableSample.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <initializer_list>
#include <vector>

namespace wallpaper::media
{
namespace
{

using Unit = std::vector<std::uint8_t>;

/// An H.264 NAL unit: header byte, then two payload bytes.
Unit Avc(unsigned refIdc, unsigned type) { return { static_cast<std::uint8_t>((refIdc << 5) | type), 0x88, 0x84 }; }

/// An HEVC NAL unit: two header bytes, then two payload bytes.
Unit Hevc(unsigned type, unsigned temporalId, unsigned layer = 0)
{
    return { static_cast<std::uint8_t>((type << 1) | (layer >> 5)),
             static_cast<std::uint8_t>(((layer & 31U) << 3) | (temporalId + 1U)), 0xAF, 0x09 };
}

/// One sample: each unit behind a big-endian length of `lengthSize` bytes.
std::vector<std::uint8_t> Sample(std::initializer_list<Unit> units, std::size_t lengthSize = 4)
{
    std::vector<std::uint8_t> bytes;
    for (const Unit& unit : units) {
        for (std::size_t index = lengthSize; index-- > 0;) {
            bytes.push_back(static_cast<std::uint8_t>((unit.size() >> (8 * index)) & 0xFFU));
        }
        bytes.insert(bytes.end(), unit.begin(), unit.end());
    }
    return bytes;
}

VideoStreamInfo AvcStream(unsigned lengthSizeMinusOne = 3)
{
    VideoStreamInfo info;
    info.codecFourcc  = FourCC('a', 'v', 'c', '1');
    info.configFourcc = FourCC('a', 'v', 'c', 'C');
    info.codecConfig  = { 1, 100, 0, 40, static_cast<std::uint8_t>(0xFC | lengthSizeMinusOne), 0xE0, 0 };
    return info;
}

VideoStreamInfo HevcStream(unsigned temporalLayers, unsigned lengthSizeMinusOne = 3)
{
    VideoStreamInfo info;
    info.codecFourcc  = FourCC('h', 'v', 'c', '1');
    info.configFourcc = FourCC('h', 'v', 'c', 'C');
    info.codecConfig.assign(23, 0);
    info.codecConfig[0]  = 1;
    info.codecConfig[21] = static_cast<std::uint8_t>((temporalLayers << 3) | lengthSizeMinusOne);
    return info;
}

bool Disposable(const VideoStreamInfo& info, const std::vector<std::uint8_t>& sample)
{
    return IsDisposableSample(info, sample.data(), sample.size());
}

TEST(DisposableSample, AnH264PictureNothingRefersToIsDisposable)
{
    const auto info = AvcStream();
    EXPECT_TRUE(Disposable(info, Sample({ Avc(0, 1) })));
    // Several slices, all non-reference, and the units a picture may carry beside them.
    EXPECT_TRUE(Disposable(info, Sample({ Avc(0, 9), Avc(0, 6), Avc(0, 1), Avc(0, 1), Avc(0, 12) })));
    // Data partitions of a non-reference picture.
    EXPECT_TRUE(Disposable(info, Sample({ Avc(0, 2), Avc(0, 3), Avc(0, 4) })));
    // Every length size the record allows.
    EXPECT_TRUE(Disposable(AvcStream(0), Sample({ Avc(0, 1) }, 1)));
    EXPECT_TRUE(Disposable(AvcStream(1), Sample({ Avc(0, 1) }, 2)));
}

TEST(DisposableSample, AnH264PictureSomethingMayReferToIsKept)
{
    const auto info = AvcStream();
    for (unsigned refIdc = 1; refIdc <= 3; ++refIdc) EXPECT_FALSE(Disposable(info, Sample({ Avc(refIdc, 1) })));
    EXPECT_FALSE(Disposable(info, Sample({ Avc(3, 5) }))) << "an IDR picture";
    EXPECT_FALSE(Disposable(info, Sample({ Avc(0, 1), Avc(2, 1) }))) << "one reference slice among them";
    EXPECT_FALSE(Disposable(info, Sample({ Avc(3, 7), Avc(3, 8), Avc(0, 1) }))) << "parameter sets in band";
    EXPECT_FALSE(Disposable(info, Sample({ Avc(0, 1), Avc(0, 10) }))) << "an end of sequence";
    EXPECT_FALSE(Disposable(info, Sample({ Avc(0, 6), Avc(0, 9) }))) << "no slice at all";
    EXPECT_FALSE(Disposable(info, Sample({ Avc(0, 20) }))) << "a slice extension";
}

TEST(DisposableSample, AnHevcNonReferencePictureIsDisposableOnlyOnTheHighestSubLayer)
{
    // TRAIL_N, TSA_N, STSA_N, RADL_N, RASL_N and the reserved non-reference types.
    for (const unsigned type : { 0U, 2U, 4U, 6U, 8U, 10U, 12U, 14U }) {
        EXPECT_TRUE(Disposable(HevcStream(1), Sample({ Hevc(type, 0) }))) << type;
        EXPECT_TRUE(Disposable(HevcStream(3), Sample({ Hevc(35, 2), Hevc(39, 2), Hevc(type, 2), Hevc(40, 2) })))
            << type;
        // A lower sub-layer's non-reference picture may still be referred to above it.
        EXPECT_FALSE(Disposable(HevcStream(3), Sample({ Hevc(type, 1) }))) << type;
    }
}

TEST(DisposableSample, AnHevcPictureSomethingMayReferToIsKept)
{
    const auto info = HevcStream(1);
    for (const unsigned type : { 1U, 3U, 5U, 7U, 9U, 16U, 19U, 20U, 21U }) {
        EXPECT_FALSE(Disposable(info, Sample({ Hevc(type, 0) }))) << type;
    }
    EXPECT_FALSE(Disposable(info, Sample({ Hevc(32, 0), Hevc(33, 0), Hevc(34, 0), Hevc(0, 0) })))
        << "parameter sets in band";
    EXPECT_FALSE(Disposable(info, Sample({ Hevc(0, 0, 1) }))) << "a picture of another layer";
    EXPECT_FALSE(Disposable(info, Sample({ Hevc(0, 0), Hevc(36, 0) }))) << "an end of sequence";
    EXPECT_FALSE(Disposable(HevcStream(0), Sample({ Hevc(0, 0) }))) << "the record states no sub-layers";
}

TEST(DisposableSample, WhatCannotBeReadIsKept)
{
    const auto info = AvcStream();
    const auto good = Sample({ Avc(0, 1) });
    EXPECT_FALSE(IsDisposableSample(info, nullptr, 0));
    EXPECT_FALSE(IsDisposableSample(info, good.data(), 0));
    // A length past the end, a length that is cut, a zero length.
    EXPECT_FALSE(Disposable(info, { 0, 0, 0, 9, 0x01, 0x88 }));
    EXPECT_FALSE(Disposable(info, { 0, 0 }));
    EXPECT_FALSE(Disposable(info, { 0, 0, 0, 0, 0, 0, 0, 3, 0x01, 0x88, 0x84 }));
    // A record too short to give the length size, or giving one neither format allows.
    VideoStreamInfo shortRecord = info;
    shortRecord.codecConfig.resize(4);
    EXPECT_FALSE(Disposable(shortRecord, good));
    EXPECT_FALSE(Disposable(AvcStream(2), Sample({ Avc(0, 1) }, 3)));
    VideoStreamInfo shortHevc = HevcStream(1);
    shortHevc.codecConfig.resize(22);
    EXPECT_FALSE(Disposable(shortHevc, Sample({ Hevc(0, 0) })));
}

TEST(DisposableSample, OtherCodecsAreNeverDisposable)
{
    // A VP9 or AV1 sample is not a sequence of NAL units: these bytes would read as
    // a non-reference H.264 slice.
    const auto bytes = Sample({ Avc(0, 1) });
    for (const auto config : { FourCC('v', 'p', 'c', 'C'), FourCC('a', 'v', '1', 'C'), 0U }) {
        VideoStreamInfo info = AvcStream();
        info.configFourcc    = config;
        EXPECT_FALSE(Disposable(info, bytes));
    }
}

} // namespace
} // namespace wallpaper::media
