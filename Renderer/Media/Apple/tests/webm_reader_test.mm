// WebMReader, the Objective-C face of the Matroska reader that the desktop player and the
// lock-screen extension play WebM files through: the properties of real clips, the
// sample buffers it hands out (timing, key frames, decodable by VideoToolbox), seeking,
// the audio decoded to PCM, the refusals, orientation and the poster image.
//
// Nothing here plays: samples are decoded by VideoToolbox sessions with no output
// device, and audio is read as buffers.
#include "Media/tests/mkv_builder.hpp"
#include "Sound/tests/matroska_fixture_data.hpp"
#include "embedded_clips.hpp"

#import "WebMReader.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

#include <gtest/gtest.h>

#include <cmath>
#include <vector>

namespace
{

namespace tm = wallpaper::video::testing_media;
using wallpaper::media::testing::Bytes;

template <std::size_t N>
WMWebMFile* Open(const unsigned char (&clip)[N], NSError** error = nil)
{
    return [WMWebMFile openWithData:[NSData dataWithBytes:clip length:N] error:error];
}

WMWebMFile* OpenBytes(const Bytes& bytes, NSError** error = nil)
{
    return [WMWebMFile openWithData:[NSData dataWithBytes:bytes.data() length:bytes.size()] error:error];
}

/// Every sample of the reader, each released after `visit` has seen it.
template <typename Visit>
std::size_t ForEachSample(WMWebMVideoReader* reader, Visit visit)
{
    std::size_t count = 0;
    while (CMSampleBufferRef sample = [reader copyNextSampleBuffer]) {
        visit(sample);
        CFRelease(sample);
        ++count;
    }
    return count;
}

bool IsSync(CMSampleBufferRef sample)
{
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (attachments == nullptr || CFArrayGetCount(attachments) == 0) return true;
    auto dictionary = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
    return ! CFDictionaryContainsKey(dictionary, kCMSampleAttachmentKey_NotSync);
}

/// The number of pictures VideoToolbox decodes from every sample the reader returns.
std::size_t DecodedFrames(WMWebMFile* file)
{
    VTDecompressionSessionRef session = nullptr;
    NSDictionary* attributes = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) };
    if (VTDecompressionSessionCreate(nullptr, file.videoFormatDescription, nullptr, (__bridge CFDictionaryRef)attributes, nullptr, &session) != noErr) {
        ADD_FAILURE() << "a decompression session could not be made";
        return 0;
    }
    __block std::size_t pictures = 0;
    WMWebMVideoReader* reader = [file makeVideoReader];
    while (CMSampleBufferRef sample = [reader copyNextSampleBuffer]) {
        VTDecompressionSessionDecodeFrameWithOutputHandler(
            session, sample, 0, nullptr,
            ^(OSStatus status, VTDecodeInfoFlags, CVImageBufferRef image, CMTime, CMTime) {
                if (status == noErr && image != nullptr) ++pictures;
            });
        CFRelease(sample);
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session);
    VTDecompressionSessionInvalidate(session);
    CFRelease(session);
    return pictures;
}

TEST(WebMReaderTest, DescribesAVp9ClipFromWebM)
{
    NSError* error = nil;
    WMWebMFile* file = Open(tm::kVp9Webm, &error);
    ASSERT_NE(file, nil) << error.localizedDescription.UTF8String;
    EXPECT_STREQ(file.containerName.UTF8String, "WebM");
    EXPECT_STREQ(file.videoCodecName.UTF8String, "VP9");
    EXPECT_EQ(file.codedSize.width, tm::kVp9WebmWidth);
    EXPECT_EQ(file.codedSize.height, tm::kVp9WebmHeight);
    EXPECT_EQ(file.presentationSize.width, tm::kVp9WebmWidth);
    EXPECT_EQ(file.frameCount, tm::kVp9WebmFrames);
    EXPECT_EQ(file.bitDepth, 8);
    EXPECT_NEAR(file.nominalFrameRate, 30.0, 0.5);
    EXPECT_NEAR(CMTimeGetSeconds(file.duration), 1.0, 0.05);
    EXPECT_NEAR(CMTimeGetSeconds(file.firstPresentationTime), 0.0, 0.001);
    EXPECT_FALSE(file.hasPlayableAudio);
    EXPECT_EQ(file.audioCodecName, nil);
    ASSERT_NE(file.videoFormatDescription, nullptr);
    EXPECT_EQ(CMFormatDescriptionGetMediaSubType(file.videoFormatDescription), static_cast<FourCharCode>(kCMVideoCodecType_VP9));
    const CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(file.videoFormatDescription);
    EXPECT_EQ(dimensions.width, tm::kVp9WebmWidth);
    EXPECT_TRUE(CGAffineTransformIsIdentity(file.preferredTransform));
    EXPECT_FALSE(file.transformSwapsAxes);
}

TEST(WebMReaderTest, ReturnsEverySampleInDecodeOrderWithTheFilesTiming)
{
    WMWebMFile* file = Open(tm::kVp9Webm);
    ASSERT_NE(file, nil);
    WMWebMVideoReader* reader = [file makeVideoReader];
    std::vector<double> dts;
    std::size_t         sync = 0;
    bool                firstIsSync = false;
    const std::size_t count = ForEachSample(reader, [&](CMSampleBufferRef sample) {
        if (dts.empty()) firstIsSync = IsSync(sample);
        if (IsSync(sample)) ++sync;
        dts.push_back(CMTimeGetSeconds(CMSampleBufferGetDecodeTimeStamp(sample)));
        EXPECT_TRUE(CMSampleBufferIsValid(sample));
        EXPECT_GT(CMSampleBufferGetTotalSampleSize(sample), 0u);
    });
    EXPECT_EQ(count, static_cast<std::size_t>(tm::kVp9WebmFrames));
    EXPECT_TRUE(reader.atEnd);
    EXPECT_EQ(reader.error, nil);
    EXPECT_TRUE(firstIsSync);
    EXPECT_EQ(sync, 2u);  // key frames at 0 and at frame 15
    for (std::size_t index = 1; index < dts.size(); ++index) EXPECT_GE(dts[index], dts[index - 1]);
}

TEST(WebMReaderTest, TheTimeOffsetShiftsEveryTimestampAndSeekingStartsAtAKeyFrame)
{
    WMWebMFile* file = Open(tm::kVp9Webm);
    ASSERT_NE(file, nil);
    WMWebMVideoReader* reader = [file makeVideoReader];
    reader.timeOffset = CMTimeMake(5, 1);
    CMSampleBufferRef first = [reader copyNextSampleBuffer];
    ASSERT_NE(first, nullptr);
    EXPECT_NEAR(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(first)), 5.0, 0.001);
    CFRelease(first);

    // A seek to 0.7 s lands on the key frame at frame 15 (0.5 s) and returns its own time.
    const CMTime landed = [reader seekToTime:CMTimeMakeWithSeconds(0.7, 1000)];
    EXPECT_NEAR(CMTimeGetSeconds(landed), 0.5, 0.01);
    CFRelease([reader copyNextSampleBuffer]);
    EXPECT_FALSE(reader.atEnd);
    // The rest of the file is what is left after frame 15, with the offset still applied.
    std::size_t left = 1;
    left += ForEachSample(reader, [&](CMSampleBufferRef sample) { EXPECT_GT(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), 5.4); });
    EXPECT_EQ(left, static_cast<std::size_t>(tm::kVp9WebmFrames - 15));
    // Seeking before everything starts at the first key frame again.
    EXPECT_NEAR(CMTimeGetSeconds([reader seekToTime:kCMTimeZero]), 0.0, 0.001);
    EXPECT_FALSE(reader.atEnd);
}

TEST(WebMReaderTest, VideoToolboxDecodesTheVp9Samples)
{
    WMWebMFile* file = Open(tm::kVp9Webm);
    ASSERT_NE(file, nil);
    EXPECT_EQ(DecodedFrames(file), static_cast<std::size_t>(tm::kVp9WebmFrames));
}

TEST(WebMReaderTest, VideoToolboxDecodesH264WithBFramesFromMatroska)
{
    NSError* error = nil;
    WMWebMFile* file = Open(tm::kH264Matroska, &error);
    ASSERT_NE(file, nil) << error.localizedDescription.UTF8String;
    EXPECT_STREQ(file.containerName.UTF8String, "Matroska");
    EXPECT_STREQ(file.videoCodecName.UTF8String, "H.264");
    EXPECT_EQ(file.frameCount, tm::kH264MatroskaFrames);
    EXPECT_EQ(DecodedFrames(file), static_cast<std::size_t>(tm::kH264MatroskaFrames));
    // With reordering, decode times lag presentation times: the first sample's differ.
    WMWebMVideoReader* reader = [file makeVideoReader];
    bool laggedAtLeastOnce = false;
    ForEachSample(reader, [&](CMSampleBufferRef sample) {
        const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
        const CMTime dts = CMSampleBufferGetDecodeTimeStamp(sample);
        EXPECT_LE(CMTimeCompare(dts, pts), 0);
        if (CMTimeCompare(dts, pts) < 0) laggedAtLeastOnce = true;
    });
    EXPECT_TRUE(laggedAtLeastOnce);
}

TEST(WebMReaderTest, TheAudioTrackDecodesToPcmBuffersOnTheFilesTimeline)
{
    NSError* error = nil;
    WMWebMFile* file = Open(wallpaper::sound::fixtures::kOpusWebm, &error);
    ASSERT_NE(file, nil) << error.localizedDescription.UTF8String;
    EXPECT_TRUE(file.hasPlayableAudio);
    EXPECT_STREQ(file.audioCodecName.UTF8String, "Opus");
    EXPECT_EQ(file.audioUnavailableReason, nil);
    WMWebMAudioReader* audio = [file makeAudioReaderWithError:&error];
    ASSERT_NE(audio, nil) << error.localizedDescription.UTF8String;
    EXPECT_EQ(audio.sampleRate, 48000);
    EXPECT_EQ(audio.channelCount, 2);

    auto drain = [&](CMTime* firstTime) {
        std::size_t frames = 0;
        while (CMSampleBufferRef buffer = [audio copyNextSampleBuffer]) {
            if (frames == 0 && firstTime != nullptr) *firstTime = CMSampleBufferGetPresentationTimeStamp(buffer);
            EXPECT_EQ(CMSampleBufferGetNumSamples(buffer), CMSampleBufferGetNumSamples(buffer));
            frames += static_cast<std::size_t>(CMSampleBufferGetNumSamples(buffer));
            CFRelease(buffer);
        }
        return frames;
    };
    CMTime first = kCMTimeInvalid;
    const std::size_t whole = drain(&first);
    EXPECT_NEAR(static_cast<double>(whole), 24000.0, 1000.0);
    EXPECT_NEAR(CMTimeGetSeconds(first), 0.0, 0.001);
    EXPECT_TRUE(audio.atEnd);

    // Rewound a second later and cut to a quarter second: the buffers start on the shifted
    // timeline and stop at the limit.
    [audio rewindWithTimeOffset:CMTimeMake(1, 1) limit:CMTimeMake(1, 4)];
    const std::size_t cut = drain(&first);
    EXPECT_EQ(cut, 12000u);
    EXPECT_NEAR(CMTimeGetSeconds(first), 1.0, 0.001);
    // And with no limit it plays whole again.
    [audio rewindWithTimeOffset:kCMTimeZero limit:kCMTimeInvalid];
    EXPECT_EQ(drain(&first), whole);
}

TEST(WebMReaderTest, AnAudioTrackThatCannotBeDecodedIsReportedAndLeftOut)
{
    wallpaper::media::testing::MkvSpec spec;
    wallpaper::media::testing::TrackSpec video;
    spec.tracks.push_back(video);
    wallpaper::media::testing::TrackSpec audio;
    audio.number  = 2;
    audio.type    = 2;
    audio.codecId = "A_OPUS";
    audio.codecPrivate = { 'O', 'p', 'u', 's', 'H', 'e', 'a', 'd', 1, 6, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 1, 4, 2, 0, 4, 1, 2, 3, 5 };
    spec.tracks.push_back(audio);
    const Bytes key { 0x82, 0x49, 0x83, 0x42, 0x00, 0x03, 0xf0, 0x02, 0xf6, 0x04, 0x38, 0x24, 0x1c, 0x18, 0x42, 0x00, 0x01, 0xb0, 0x7c, 0xb1, 0xfa, 0xdb, 0x72, 0xf4 };
    wallpaper::media::testing::ClusterSpec cluster;
    wallpaper::media::testing::BlockSpec   videoBlock;
    videoBlock.frames.push_back(key);
    cluster.blocks.push_back(videoBlock);
    wallpaper::media::testing::BlockSpec audioBlock;
    audioBlock.track = 2;
    audioBlock.frames.push_back({ 0xFC, 0xFF, 0xFE });
    cluster.blocks.push_back(audioBlock);
    spec.clusters.push_back(cluster);
    NSError* error = nil;
    WMWebMFile* file = OpenBytes(wallpaper::media::testing::BuildMkv(spec).bytes, &error);
    ASSERT_NE(file, nil) << error.localizedDescription.UTF8String;
    EXPECT_FALSE(file.hasPlayableAudio);
    EXPECT_STREQ(file.audioCodecName.UTF8String, "Opus");
    EXPECT_NE(file.audioUnavailableReason, nil);
    EXPECT_EQ([file makeAudioReaderWithError:&error], nil);
    EXPECT_EQ(error.code, WMWebMErrorUnsupportedFormat);
}

TEST(WebMReaderTest, RefusesFormatsThisMacDoesNotPlayAndNamesThem)
{
    // VP8 is a supported container codec nowhere: the error carries its name.
    wallpaper::media::testing::MkvSpec spec;
    wallpaper::media::testing::TrackSpec video;
    video.codecId = "V_VP8";
    spec.tracks.push_back(video);
    wallpaper::media::testing::ClusterSpec cluster;
    wallpaper::media::testing::BlockSpec   block;
    block.frames.push_back({ 1, 2, 3, 4 });
    cluster.blocks.push_back(block);
    spec.clusters.push_back(cluster);
    NSError* error = nil;
    EXPECT_EQ(OpenBytes(wallpaper::media::testing::BuildMkv(spec).bytes, &error), nil);
    EXPECT_EQ(error.domain, WMWebMErrorDomain);
    EXPECT_EQ(error.code, WMWebMErrorUnsupportedFormat);
    EXPECT_STREQ([error.userInfo[WMWebMFormatNameKey] UTF8String], "VP8");

    // Not Matroska at all.
    error = nil;
    const Bytes junk(64, 0x41);
    EXPECT_EQ(OpenBytes(junk, &error), nil);
    EXPECT_EQ(error.code, WMWebMErrorNotMatroska);

    // Matroska cut off inside its headers.
    error = nil;
    Bytes cut(tm::kVp9Webm, tm::kVp9Webm + 120);
    EXPECT_EQ(OpenBytes(cut, &error), nil);
    EXPECT_NE(error, nil);
    EXPECT_NE(error.code, WMWebMErrorNotMatroska);
}

TEST(WebMReaderTest, ReadsAFileFromDisk)
{
    NSString* path = [NSTemporaryDirectory() stringByAppendingFormat:@"webm-reader-%d.webm", getpid()];
    ASSERT_TRUE([[NSData dataWithBytes:tm::kVp9Webm length:sizeof(tm::kVp9Webm)] writeToFile:path atomically:YES]);
    NSError* error = nil;
    WMWebMFile* file = [WMWebMFile openAtURL:[NSURL fileURLWithPath:path] error:&error];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    ASSERT_NE(file, nil) << error.localizedDescription.UTF8String;
    EXPECT_EQ(file.frameCount, tm::kVp9WebmFrames);
    EXPECT_EQ([WMWebMFile openAtURL:[NSURL fileURLWithPath:path] error:&error], nil);
    EXPECT_EQ(error.code, WMWebMErrorUnreadable);
}

TEST(WebMReaderTest, AQuarterTurnExchangesTheAxesOfThePresentationSize)
{
    wallpaper::media::testing::MkvSpec spec;
    wallpaper::media::testing::TrackSpec video;  // 64x48
    video.poseRoll = 90.0;
    spec.tracks.push_back(video);
    wallpaper::media::testing::ClusterSpec cluster;
    wallpaper::media::testing::BlockSpec   block;
    block.frames.push_back({ 0x82, 0x49, 0x83, 0x42, 0x00, 0x03, 0xf0, 0x02, 0xf6, 0x04, 0x38, 0x24, 0x1c, 0x18, 0x42, 0x00, 0x01, 0xb0, 0x7c, 0xb1, 0xfa, 0xdb, 0x72, 0xf4 });
    cluster.blocks.push_back(block);
    spec.clusters.push_back(cluster);
    NSError* error = nil;
    WMWebMFile* file = OpenBytes(wallpaper::media::testing::BuildMkv(spec).bytes, &error);
    ASSERT_NE(file, nil) << error.localizedDescription.UTF8String;
    EXPECT_TRUE(file.transformSwapsAxes);
    EXPECT_EQ(file.codedSize.width, 64);
    EXPECT_EQ(file.presentationSize.width, 48);
    EXPECT_EQ(file.presentationSize.height, 64);
    // The file's matrix puts the stored 64x48 picture at the origin of a 48x64 area.
    const CGRect shown = CGRectApplyAffineTransform(CGRectMake(0, 0, 64, 48), file.preferredTransform);
    EXPECT_NEAR(shown.origin.x, 0, 0.001);
    EXPECT_NEAR(shown.origin.y, 0, 0.001);
    EXPECT_NEAR(shown.size.width, 48, 0.001);
    EXPECT_NEAR(shown.size.height, 64, 0.001);
    // The layer form turns the other way round (a y-up layer) and has no translation.
    const CGAffineTransform layer = file.layerTransform;
    EXPECT_EQ(layer.a, 0);
    EXPECT_EQ(layer.b, -file.preferredTransform.b);
    EXPECT_EQ(layer.c, -file.preferredTransform.c);
    EXPECT_EQ(layer.tx, 0);
    EXPECT_EQ(layer.ty, 0);
}

TEST(WebMReaderTest, ThePosterIsTheKeyFramePictureAtOrBeforeATime)
{
    WMWebMFile* file = Open(tm::kVp9Webm);
    ASSERT_NE(file, nil);
    CGImageRef poster = [file copyPosterImageAtTime:CMTimeMakeWithSeconds(0.7, 1000)];
    ASSERT_NE(poster, nullptr);
    EXPECT_EQ(CGImageGetWidth(poster), static_cast<std::size_t>(tm::kVp9WebmWidth));
    EXPECT_EQ(CGImageGetHeight(poster), static_cast<std::size_t>(tm::kVp9WebmHeight));
    CGImageRelease(poster);

    WMWebMFile* h264 = Open(tm::kH264Matroska);
    ASSERT_NE(h264, nil);
    poster = [h264 copyPosterImageAtTime:kCMTimeZero];
    ASSERT_NE(poster, nullptr);
    EXPECT_EQ(CGImageGetWidth(poster), static_cast<std::size_t>(tm::kH264MatroskaWidth));
    CGImageRelease(poster);
}

} // namespace
