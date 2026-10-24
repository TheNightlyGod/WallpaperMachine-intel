// What the synthetic video fixture promises, read back with AVFoundation alone.
//
// The decoders under test are shown these files, so the fixture is checked here
// by a reader that shares no code with them: frame count and timing, which
// samples are keyframes, the track's display matrix, the colour tags, and the
// pictures the encoder was asked for.

#include "synthetic_video.hpp"
#include "video_orientation_cases.hpp"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <gtest/gtest.h>

#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace wallpaper::video::testing_media
{
namespace
{

class SyntheticVideo : public ::testing::Test {
protected:
    void SetUp() override {
        ASSERT_TRUE(EncoderAvailable())
            << "VideoToolbox H.264 encoding is unavailable, so no synthetic media can be made";
        static std::atomic<uint64_t> serial { 0 };
        directory = std::filesystem::temp_directory_path() /
                    ("owe-synthetic-video-" + std::to_string(::getpid()) + "-" +
                     std::to_string(serial.fetch_add(1)));
        std::filesystem::create_directories(directory);
    }
    void TearDown() override {
        std::error_code ec;
        std::filesystem::remove_all(directory, ec);
    }
    std::filesystem::path directory;
};

AVURLAsset* OpenAsset(const std::filesystem::path& path) {
    return [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]]
                               options:nil];
}

AVAssetTrack* VideoTrack(AVURLAsset* asset) {
    // The tracks load asynchronously; a local file answers at once, and a test
    // has nothing better to do than wait.
    __block NSArray<AVAssetTrack*>* tracks = nil;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeVideo
                 completionHandler:^(NSArray<AVAssetTrack*>* result, NSError*) {
                     tracks = result;
                     dispatch_semaphore_signal(loaded);
                 }];
    if (dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0) {
        return nil;
    }
    return tracks.count == 1 ? tracks.firstObject : nil;
}

struct SampleInfo {
    double presentation { 0 };
    bool   sync { false };
};

/// Every compressed sample of the video track, in file order.
std::vector<SampleInfo> ReadCompressedSamples(AVURLAsset* asset) {
    std::vector<SampleInfo> samples;
    AVAssetTrack* track = VideoTrack(asset);
    if (track == nil) return samples;
    NSError*       error  = nil;
    AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    AVAssetReaderTrackOutput* output =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
    if (reader == nil || ![reader canAddOutput:output]) return samples;
    [reader addOutput:output];
    if (![reader startReading]) return samples;
    while (true) {
        @autoreleasepool {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (sample == nullptr) break;
            // The reader brackets a track with empty marker buffers (no sample,
            // no data); they are not frames.
            if (CMSampleBufferGetNumSamples(sample) == 0) {
                CFRelease(sample);
                continue;
            }
            SampleInfo info;
            info.presentation = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
            info.sync         = true;
            CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
            if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
                auto* dictionary = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
                CFTypeRef not_sync = CFDictionaryGetValue(dictionary, kCMSampleAttachmentKey_NotSync);
                info.sync = not_sync == nullptr ||
                            !CFBooleanGetValue(static_cast<CFBooleanRef>(not_sync));
            }
            samples.push_back(info);
            CFRelease(sample);
        }
    }
    return samples;
}

/// The luma plane of every frame `wanted` names, decoded to 4:2:0 video range
/// by AVFoundation. Indexed by position in `wanted`.
std::vector<std::vector<uint8_t>> DecodeLuma(AVURLAsset* asset, const std::vector<int>& wanted) {
    std::vector<std::vector<uint8_t>> frames(wanted.size());
    AVAssetTrack* track = VideoTrack(asset);
    if (track == nil) return frames;
    NSError*       error  = nil;
    AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    NSDictionary*  settings = @{
        (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey :
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    };
    AVAssetReaderTrackOutput* output =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    if (reader == nil || ![reader canAddOutput:output]) return frames;
    [reader addOutput:output];
    if (![reader startReading]) return frames;
    for (int index = 0;; ++index) {
        @autoreleasepool {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (sample == nullptr) break;
            if (CMSampleBufferGetNumSamples(sample) == 0) {
                CFRelease(sample);
                --index;
                continue;
            }
            const auto found = std::find(wanted.begin(), wanted.end(), index);
            if (found != wanted.end()) {
                CVPixelBufferRef picture = CMSampleBufferGetImageBuffer(sample);
                CVPixelBufferLockBaseAddress(picture, kCVPixelBufferLock_ReadOnly);
                const auto* plane  = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(picture, 0));
                const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(picture, 0);
                std::vector<uint8_t> luma(static_cast<size_t>(kFrameWidth * kFrameHeight));
                for (int y = 0; y < kFrameHeight; ++y) {
                    std::copy_n(plane + static_cast<size_t>(y) * stride, kFrameWidth,
                                luma.begin() + y * kFrameWidth);
                }
                CVPixelBufferUnlockBaseAddress(picture, kCVPixelBufferLock_ReadOnly);
                frames[static_cast<size_t>(std::distance(wanted.begin(), found))] = std::move(luma);
            }
            CFRelease(sample);
        }
    }
    return frames;
}

std::vector<char> ReadFile(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    return { std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>() };
}

} // namespace

TEST_F(SyntheticVideo, ARepeatedClipHoldsEveryFrameAtItsOwnTime)
{
    constexpr int kRepeats = 3;
    const auto    path     = directory / "repeated.mp4";
    ASSERT_TRUE(WriteSyntheticVideo(path, kRepeats, "repeated"));

    AVURLAsset* asset = OpenAsset(path);
    AVAssetTrack* track = VideoTrack(asset);
    ASSERT_NE(track, nil) << "the file has no single video track";
    EXPECT_EQ(static_cast<int>(track.naturalSize.width), kFrameWidth);
    EXPECT_EQ(static_cast<int>(track.naturalSize.height), kFrameHeight);
    EXPECT_NEAR(CMTimeGetSeconds(asset.duration), kRepeats * kGopFrames / 30.0, 1e-3);
    EXPECT_NEAR(static_cast<double>(track.nominalFrameRate), 30.0, 0.01);

    const auto samples = ReadCompressedSamples(asset);
    ASSERT_EQ(samples.size(), static_cast<size_t>(kRepeats * kGopFrames));
    for (size_t index = 0; index < samples.size(); ++index) {
        EXPECT_NEAR(samples[index].presentation, static_cast<double>(index) / 30.0, 1e-6)
            << "frame " << index;
        // Each repeat is a whole group of pictures: it starts on a keyframe,
        // and nothing else in it is one.
        EXPECT_EQ(samples[index].sync, index % kGopFrames == 0) << "frame " << index;
    }
}

TEST_F(SyntheticVideo, TheSaltMakesTwoOtherwiseEqualFilesDiffer)
{
    ASSERT_TRUE(WriteSyntheticVideo(directory / "a.mp4", 1, "salt-a"));
    ASSERT_TRUE(WriteSyntheticVideo(directory / "b.mp4", 1, "salt-b"));
    const auto a = ReadFile(directory / "a.mp4");
    const auto b = ReadFile(directory / "b.mp4");
    EXPECT_FALSE(a.empty());
    EXPECT_NE(a, b);
    // Whatever the container does with the salt, the pictures are the same
    // compressed samples: the files differ by a few bytes, not by a re-encode.
    EXPECT_NEAR(static_cast<double>(a.size()), static_cast<double>(b.size()), 64.0);
}

TEST_F(SyntheticVideo, AWrittenFileGrowsWithItsRepeats)
{
    ASSERT_TRUE(WriteSyntheticVideo(directory / "one.mp4", 1, "growth"));
    ASSERT_TRUE(WriteSyntheticVideo(directory / "four.mp4", 4, "growth"));
    const auto one  = static_cast<double>(std::filesystem::file_size(directory / "one.mp4"));
    const auto four = static_cast<double>(std::filesystem::file_size(directory / "four.mp4"));
    EXPECT_NEAR(four / one, 4.0, 0.1);
}

TEST_F(SyntheticVideo, EveryOrientationIsWrittenToTheTrackHeader)
{
    for (const auto& orientation : kOrientations) {
        SCOPED_TRACE(orientation.name);
        const auto path = directory / (std::string(orientation.name) + ".mp4");
        ASSERT_TRUE(WriteSyntheticVideo(path, 1, orientation.name, orientation.matrix()));
        AVAssetTrack* track = VideoTrack(OpenAsset(path));
        ASSERT_NE(track, nil);
        const CGAffineTransform transform = track.preferredTransform;
        EXPECT_EQ(static_cast<int>(transform.a), orientation.a);
        EXPECT_EQ(static_cast<int>(transform.b), orientation.b);
        EXPECT_EQ(static_cast<int>(transform.c), orientation.c);
        EXPECT_EQ(static_cast<int>(transform.d), orientation.d);
        EXPECT_EQ(transform.tx, 0.0);
        EXPECT_EQ(transform.ty, 0.0);
    }
}

TEST_F(SyntheticVideo, AClipWithoutAMatrixHasTheIdentityOne)
{
    ASSERT_TRUE(WriteSyntheticVideo(directory / "plain.mp4", 1, "plain"));
    const CGAffineTransform transform = VideoTrack(OpenAsset(directory / "plain.mp4")).preferredTransform;
    EXPECT_TRUE(CGAffineTransformIsIdentity(transform));
}

TEST_F(SyntheticVideo, TheColourIsNotTagged)
{
    // The tests' absolute colours rest on the decoder having to infer the
    // matrix from the picture size, as it did for the clips FFmpeg muxed. A
    // writer that tagged the stream would change every one of those colours.
    ASSERT_TRUE(WriteSyntheticVideo(directory / "untagged.mp4", 1, "untagged"));
    AVAssetTrack* track = VideoTrack(OpenAsset(directory / "untagged.mp4"));
    ASSERT_NE(track, nil);
    ASSERT_EQ(track.formatDescriptions.count, 1u);
    auto description = static_cast<CMFormatDescriptionRef>((__bridge void*)track.formatDescriptions.firstObject);
    for (CFStringRef key : { kCMFormatDescriptionExtension_ColorPrimaries,
                             kCMFormatDescriptionExtension_TransferFunction,
                             kCMFormatDescriptionExtension_YCbCrMatrix }) {
        CFTypeRef value = CMFormatDescriptionGetExtension(description, key);
        EXPECT_EQ(value, nullptr) << "colour extension written: " << [(__bridge NSString*)key UTF8String];
    }
}

TEST_F(SyntheticVideo, TheDecodedPicturesAreThePicturesTheEncoderWasGiven)
{
    ASSERT_TRUE(WriteSyntheticVideo(directory / "noise.mp4", 1, "noise"));
    const std::vector<int> wanted { 0, 7, 29 };
    const auto frames = DecodeLuma(OpenAsset(directory / "noise.mp4"), wanted);
    for (size_t slot = 0; slot < wanted.size(); ++slot) {
        SCOPED_TRACE("frame " + std::to_string(wanted[slot]));
        ASSERT_EQ(frames[slot].size(), static_cast<size_t>(kFrameWidth * kFrameHeight));
        double error = 0;
        for (int y = 0; y < kFrameHeight; ++y) {
            for (int x = 0; x < kFrameWidth; ++x) {
                error += std::abs(
                    static_cast<int>(frames[slot][static_cast<size_t>(y * kFrameWidth + x)]) -
                    static_cast<int>(FrameLuma(wanted[slot], x, y)));
            }
        }
        // Noise at 200 Mbit/s is close to lossless; a picture that did not come
        // from this frame misses by about a third of the range.
        EXPECT_LT(error / (kFrameWidth * kFrameHeight), 12.0);
    }
}

TEST_F(SyntheticVideo, TheLongClipIsOneGroupOfPicturesWhoseBarCrossesThePicture)
{
    EXPECT_EQ(LongGopKeyframes(), 1);
    const auto path = directory / "long.mp4";
    ASSERT_TRUE(WriteLongGopVideo(path, "long"));

    AVURLAsset* asset = OpenAsset(path);
    EXPECT_NEAR(CMTimeGetSeconds(asset.duration), kLongGopFrames / 30.0, 1e-3);
    const auto samples = ReadCompressedSamples(asset);
    ASSERT_EQ(samples.size(), static_cast<size_t>(kLongGopFrames));
    EXPECT_EQ(std::count_if(samples.begin(), samples.end(),
                            [](const SampleInfo& sample) { return sample.sync; }), 1);
    EXPECT_TRUE(samples.front().sync);

    const std::vector<int> wanted { 0, 150, 450, kLongGopFrames - 1 };
    const auto frames = DecodeLuma(asset, wanted);
    for (size_t slot = 0; slot < wanted.size(); ++slot) {
        SCOPED_TRACE("frame " + std::to_string(wanted[slot]));
        ASSERT_EQ(frames[slot].size(), static_cast<size_t>(kFrameWidth * kFrameHeight));
        // The middle row: the first bright column is the bar's left edge.
        const auto* row = frames[slot].data() + (kFrameHeight / 2) * kFrameWidth;
        int left = -1;
        for (int x = 0; x < kFrameWidth; ++x) {
            if (row[x] > 150) { left = x; break; }
        }
        EXPECT_NEAR(left, LongGopBarColumn(wanted[slot]), 2);
        EXPECT_NEAR(LongGopFrameOfColumn(left), wanted[slot], 3);
    }
}


// ---- 10-bit clips ---------------------------------------------------------------

namespace
{

class SyntheticTenBitVideo : public ::testing::Test {
protected:
    void SetUp() override {
        if (!TenBitEncoderAvailable()) GTEST_SKIP() << "no VideoToolbox HEVC Main10 encoder on this machine";
        static std::atomic<uint64_t> serial { 0 };
        directory = std::filesystem::temp_directory_path() /
                    ("owe-synthetic-tenbit-" + std::to_string(::getpid()) + "-" +
                     std::to_string(serial.fetch_add(1)));
        std::filesystem::create_directories(directory);
    }
    void TearDown() override {
        std::error_code ec;
        std::filesystem::remove_all(directory, ec);
    }
    std::filesystem::path directory;
};

CFStringRef ExtensionString(AVAssetTrack* track, CFStringRef key) {
    auto description = static_cast<CMFormatDescriptionRef>((__bridge void*)track.formatDescriptions.firstObject);
    return static_cast<CFStringRef>(CMFormatDescriptionGetExtension(description, key));
}

} // namespace

TEST_F(SyntheticTenBitVideo, EveryTaggingIsHevcMain10AndCarriesItsTagsInTheContainer)
{
    struct Case {
        TenBitTagging tagging;
        CFStringRef   primaries;
        CFStringRef   transfer;
        CFStringRef   matrix;
    };
    const Case cases[] = {
        { TenBitTagging::Pq, kCMFormatDescriptionColorPrimaries_ITU_R_2020,
          kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 },
        { TenBitTagging::Hlg, kCMFormatDescriptionColorPrimaries_ITU_R_2020,
          kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 },
        { TenBitTagging::Bt709, kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
          kCMFormatDescriptionTransferFunction_ITU_R_709_2, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 },
    };
    int index = 0;
    for (const Case& test : cases) {
        const auto path = directory / ("tagged-" + std::to_string(index++) + ".mp4");
        ASSERT_TRUE(WriteTenBitVideo(path, test.tagging, TenBitPicture {}, "tagged"));
        AVURLAsset*   asset = OpenAsset(path);
        AVAssetTrack* track = VideoTrack(asset);
        ASSERT_NE(track, nil);
        ASSERT_EQ(track.formatDescriptions.count, 1u);
        auto description = static_cast<CMFormatDescriptionRef>((__bridge void*)track.formatDescriptions.firstObject);
        EXPECT_EQ(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_HEVC);
        const CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(description);
        EXPECT_EQ(size.width, kFrameWidth);
        EXPECT_EQ(size.height, kFrameHeight);
        // Main10, and 10 bits in both planes, read from the hvcC record itself.
        auto atoms = static_cast<CFDictionaryRef>(
            CMFormatDescriptionGetExtension(description, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
        ASSERT_NE(atoms, nullptr);
        auto hvcc = static_cast<CFDataRef>(CFDictionaryGetValue(atoms, CFSTR("hvcC")));
        ASSERT_NE(hvcc, nullptr);
        ASSERT_GE(CFDataGetLength(hvcc), 23);
        const UInt8* record = CFDataGetBytePtr(hvcc);
        EXPECT_EQ(record[1] & 0x1F, 2) << "general_profile_idc 2 is Main 10";
        EXPECT_EQ(8 + (record[17] & 0x07), 10) << "luma bit depth";
        EXPECT_EQ(8 + (record[18] & 0x07), 10) << "chroma bit depth";
        EXPECT_TRUE(CFEqual(ExtensionString(track, kCMFormatDescriptionExtension_ColorPrimaries), test.primaries));
        EXPECT_TRUE(CFEqual(ExtensionString(track, kCMFormatDescriptionExtension_TransferFunction), test.transfer));
        EXPECT_TRUE(CFEqual(ExtensionString(track, kCMFormatDescriptionExtension_YCbCrMatrix), test.matrix));

        const auto samples = ReadCompressedSamples(asset);
        ASSERT_EQ(samples.size(), static_cast<size_t>(kTenBitFrames));
        EXPECT_TRUE(samples.front().sync);
        for (size_t i = 0; i < samples.size(); ++i) {
            EXPECT_NEAR(samples[i].presentation, static_cast<double>(i) / 30.0, 1e-6) << i;
        }
    }
}

TEST_F(SyntheticTenBitVideo, TheDecodedTenBitPictureIsTheOneTheEncoderWasGiven)
{
    const TenBitPicture picture { 600, 440, 580 };
    const auto          path = directory / "picture.mp4";
    ASSERT_TRUE(WriteTenBitVideo(path, TenBitTagging::Pq, picture, "picture"));
    AVURLAsset*   asset = OpenAsset(path);
    AVAssetTrack* track = VideoTrack(asset);
    ASSERT_NE(track, nil);
    NSError*       error  = nil;
    AVAssetReader* reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    AVAssetReaderTrackOutput* output = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:track
                         outputSettings:@{ (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey :
                                               @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) }];
    ASSERT_TRUE(reader != nil && [reader canAddOutput:output]);
    [reader addOutput:output];
    ASSERT_TRUE([reader startReading]);
    int decoded = 0;
    while (true) {
        @autoreleasepool {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (sample == nullptr) break;
            if (CMSampleBufferGetNumSamples(sample) == 0) {
                CFRelease(sample);
                continue;
            }
            CVPixelBufferRef frame = CMSampleBufferGetImageBuffer(sample);
            ASSERT_NE(frame, nullptr);
            CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
            const auto* luma   = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(frame, 0));
            const auto* chroma = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(frame, 1));
            const size_t y_row = CVPixelBufferGetBytesPerRowOfPlane(frame, 0);
            const size_t c_row = CVPixelBufferGetBytesPerRowOfPlane(frame, 1);
            const int y = reinterpret_cast<const uint16_t*>(luma + (kFrameHeight / 2) * y_row)[kFrameWidth / 2] >> 6;
            const auto* c = reinterpret_cast<const uint16_t*>(chroma + (kFrameHeight / 4) * c_row);
            const int cb  = c[(kFrameWidth / 4) * 2] >> 6;
            const int cr  = c[(kFrameWidth / 4) * 2 + 1] >> 6;
            CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
            // The encoder is lossy, and a flat picture is the case where it is
            // closest to exact.
            EXPECT_NEAR(y, picture.y, 3) << "frame " << decoded;
            EXPECT_NEAR(cb, picture.cb, 3) << "frame " << decoded;
            EXPECT_NEAR(cr, picture.cr, 3) << "frame " << decoded;
            ++decoded;
            CFRelease(sample);
        }
    }
    EXPECT_EQ(decoded, kTenBitFrames);
}

TEST_F(SyntheticTenBitVideo, TheSaltMakesTwoOtherwiseEqualTenBitFilesDiffer)
{
    ASSERT_TRUE(WriteTenBitVideo(directory / "a.mp4", TenBitTagging::Hlg, TenBitPicture {}, "one"));
    ASSERT_TRUE(WriteTenBitVideo(directory / "b.mp4", TenBitTagging::Hlg, TenBitPicture {}, "two"));
    EXPECT_NE(ReadFile(directory / "a.mp4"), ReadFile(directory / "b.mp4"));
}

} // namespace wallpaper::video::testing_media
