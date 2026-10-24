#import "WebMReader.h"

#include "Media/Apple/FormatDescription.hpp"
#include "Media/Apple/VtFrameDecoder.hpp"
#include "Media/ByteSource.hpp"
#include "Media/DisplayMatrix.hpp"
#include "Media/Matroska/MatroskaReader.hpp"
#include "Sound/Matroska/MatroskaAudio.hpp"

#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <memory>
#include <string>
#include <vector>

using namespace wallpaper;

NSErrorDomain const WMWebMErrorDomain         = @"WMWebMErrorDomain";
NSErrorUserInfoKey const WMWebMFormatNameKey = @"WMWebMFormatName";

namespace
{

constexpr std::int32_t kNanoseconds = 1000000000;

CMTime NsTime(std::int64_t ns) { return CMTimeMake(ns, kNanoseconds); }

std::int64_t ToNs(CMTime time)
{
    if (! CMTIME_IS_NUMERIC(time)) return 0;
    return CMTimeConvertScale(time, kNanoseconds, kCMTimeRoundingMethod_Default).value;
}

NSError* MakeError(WMWebMErrorCode code, const std::string& message, NSString* format = nil)
{
    NSMutableDictionary* info = [NSMutableDictionary dictionary];
    NSString* text = [NSString stringWithUTF8String:message.c_str()];
    info[NSLocalizedDescriptionKey] = text != nil ? text : @"unknown error";
    if (format != nil) info[WMWebMFormatNameKey] = format;
    return [NSError errorWithDomain:WMWebMErrorDomain code:code userInfo:info];
}

/// "V_VP8" as a person names it.
NSString* CodecIdName(const std::string& codecId)
{
    if (codecId == "V_VP8") return @"VP8";
    if (codecId == "V_VP9") return @"VP9";
    if (codecId == "V_AV1") return @"AV1";
    if (codecId == "V_MPEG4/ISO/AVC") return @"H.264";
    if (codecId == "V_MPEGH/ISO/HEVC") return @"HEVC";
    if (codecId.rfind("V_MPEG4", 0) == 0 || codecId == "V_MS/VFW/FOURCC") return @"MPEG-4";
    if (codecId.rfind("V_MPEG", 0) == 0) return @"MPEG";
    if (codecId == "V_THEORA") return @"Theora";
    return [NSString stringWithUTF8String:codecId.c_str()];
}

/// The codec id a reader's "video codec V_VP8 is not supported" message names, or empty.
std::string CodecIdIn(const std::string& message)
{
    const std::string needle = "codec ";
    const std::size_t at     = message.find(needle);
    if (at == std::string::npos) return {};
    const std::size_t from = at + needle.size();
    const std::size_t to   = message.find(' ', from);
    return message.substr(from, to == std::string::npos ? std::string::npos : to - from);
}

NSString* VideoCodecName(media::MatroskaCodec codec)
{
    switch (codec) {
    case media::MatroskaCodec::Vp9: return @"VP9";
    case media::MatroskaCodec::Av1: return @"AV1";
    case media::MatroskaCodec::H264: return @"H.264";
    case media::MatroskaCodec::Hevc: return @"HEVC";
    case media::MatroskaCodec::Vp8: return @"VP8";
    default: return @"unknown";
    }
}

NSString* AudioCodecName(media::MatroskaCodec codec)
{
    switch (codec) {
    case media::MatroskaCodec::Opus: return @"Opus";
    case media::MatroskaCodec::Vorbis: return @"Vorbis";
    case media::MatroskaCodec::Aac: return @"AAC";
    case media::MatroskaCodec::Mp3: return @"MP3";
    default: return nil;
    }
}

NSError* ErrorFor(const media::Error& error)
{
    using media::ErrorKind;
    switch (error.kind) {
    case ErrorKind::NotThisFormat: return MakeError(WMWebMErrorNotMatroska, media::Describe(error));
    case ErrorKind::Unsupported: {
        const std::string codecId = CodecIdIn(error.message);
        return MakeError(WMWebMErrorUnsupportedFormat, media::Describe(error), codecId.empty() ? nil : CodecIdName(codecId));
    }
    case ErrorKind::Io: return MakeError(WMWebMErrorUnreadable, media::Describe(error));
    default: return MakeError(WMWebMErrorDamaged, media::Describe(error));
    }
}

/// The 2x2 part of a tkhd-style orientation, in the y-down convention AVFoundation uses
/// for `preferredTransform`.
CGAffineTransform LinearTransform(media::Orientation orientation)
{
    using media::Orientation;
    switch (orientation) {
    case Orientation::Identity: return CGAffineTransformIdentity;
    case Orientation::Rotate90: return CGAffineTransformMake(0, 1, -1, 0, 0, 0);
    case Orientation::Rotate180: return CGAffineTransformMake(-1, 0, 0, -1, 0, 0);
    case Orientation::Rotate270: return CGAffineTransformMake(0, -1, 1, 0, 0, 0);
    case Orientation::MirrorX: return CGAffineTransformMake(-1, 0, 0, 1, 0, 0);
    case Orientation::MirrorY: return CGAffineTransformMake(1, 0, 0, -1, 0, 0);
    case Orientation::Transpose: return CGAffineTransformMake(0, 1, 1, 0, 0, 0);
    case Orientation::Transverse: return CGAffineTransformMake(0, -1, -1, 0, 0, 0);
    }
    return CGAffineTransformIdentity;
}

/// `linear` moved so the picture of `size` lands in the positive quadrant, as a track
/// header's matrix carries it.
CGAffineTransform Placed(CGAffineTransform linear, CGSize size)
{
    const CGRect box = CGRectApplyAffineTransform(CGRectMake(0, 0, size.width, size.height), linear);
    linear.tx        = -box.origin.x;
    linear.ty        = -box.origin.y;
    return linear;
}

} // namespace

// What the readers need of each other; not part of the public header.
@interface WMWebMFile (Internal)
- (media::MatroskaReader&)matroska;
@end
@interface WMWebMVideoReader (Internal)
- (instancetype)initWithFile:(WMWebMFile*)file;
@end
@interface WMWebMAudioReader (Internal)
- (instancetype)initWithFile:(WMWebMFile*)file decoder:(std::unique_ptr<sound::PcmDecoder>)decoder startNs:(std::int64_t)startNs;
@end

// MARK: - File

@implementation WMWebMFile {
    std::shared_ptr<media::MatroskaReader> _reader;
    media::apple::StreamFormat             _format;
    std::size_t                            _audioTrack;
    bool                                   _hasAudioTrack;
    media::Orientation                     _orientation;
    NSString*                              _containerName;
    NSString*                              _videoCodecName;
    CGSize                                 _codedSize;
    CGSize                                 _presentationSize;
    CGSize                                 _storedSize;
    CMTime                                 _first;
    CMTime                                 _duration;
    NSInteger                              _frames;
    double                                 _frameRate;
    NSArray<NSString*>*                    _warnings;
    BOOL                                   _audioPlayable;
    NSString*                              _audioName;
    NSString*                              _audioWhy;
}

+ (instancetype)openAtURL:(NSURL*)url error:(NSError**)error
{
    media::Error read;
    auto source = media::OpenFileByteSource(std::string(url.fileSystemRepresentation), &read);
    if (source == nullptr) {
        if (error != nullptr) *error = MakeError(WMWebMErrorUnreadable, media::Describe(read));
        return nil;
    }
    return [self openSource:std::move(source) error:error];
}

+ (instancetype)openWithData:(NSData*)data error:(NSError**)error
{
    const auto* bytes = static_cast<const std::uint8_t*>(data.bytes);
    return [self openSource:media::MakeMemoryByteSource(std::vector<std::uint8_t>(bytes, bytes + data.length)) error:error];
}

+ (instancetype)openSource:(std::shared_ptr<media::ByteSource>)source error:(NSError**)error
{
    // No autorelease pool here: an error written to `*error` is autoreleased, and a pool
    // that drains before the caller reads it would free it.
    media::Error failure;
    auto reader = media::MatroskaReader::Open(std::move(source), &failure);
    if (reader == nullptr) {
        if (error != nullptr) *error = ErrorFor(failure);
        return nil;
    }
    WMWebMFile* file = [[WMWebMFile alloc] init];
    std::string why;
    if (! [file adopt:std::shared_ptr<media::MatroskaReader>(std::move(reader)) why:&why error:error]) return nil;
    return file;
}

- (BOOL)adopt:(std::shared_ptr<media::MatroskaReader>)reader why:(std::string*)why error:(NSError**)error
{
    _reader = std::move(reader);
    const media::VideoStreamInfo& info  = _reader->videoInfo();
    const media::MatroskaTrack&   track = _reader->videoTrack();
    const auto&                   samples = _reader->videoSamples();

    // The first key frame, for what the codec record does not carry.
    std::vector<std::uint8_t> first;
    if (const auto key = _reader->findVideoKeyframeAtOrBefore(std::numeric_limits<std::int64_t>::min())) {
        media::Error read;
        if (! _reader->readSample(*key, &first, &read)) first.clear();
    }
    const media::Vp9FrameHeader* vp9 = _reader->vp9KeyFrame() ? &*_reader->vp9KeyFrame() : nullptr;
    std::string refusal;
    if (! media::apple::MakeStreamFormat(info, vp9, first.data(), first.size(), &_format, &refusal)) {
        const bool unsupported = refusal.rfind(media::apple::kFormatNotSupported, 0) == 0;
        if (error != nullptr) {
            *error = MakeError(unsupported ? WMWebMErrorUnsupportedFormat : WMWebMErrorDamaged, refusal,
                               unsupported ? VideoCodecName(track.codec) : nil);
        }
        return NO;
    }

    _containerName  = _reader->info().docType == "webm" ? @"WebM" : @"Matroska";
    _videoCodecName = VideoCodecName(track.codec);
    _codedSize      = CGSizeMake(info.codedWidth, info.codedHeight);
    _orientation    = media::ClassifyDisplayMatrix(info.displayMatrix).value_or(media::Orientation::Identity);

    // The picture as the file asks it to be shown: its display size when it gives one in
    // pixels, else the coded size stretched by the pixel aspect.
    double width  = info.codedWidth;
    double height = info.codedHeight;
    if (info.displayWidth != 0 && info.displayHeight != 0) {
        width  = info.displayWidth;
        height = info.displayHeight;
    } else if (info.pixelAspect.valid() && info.pixelAspect.toDouble() > 0) {
        width = std::round(width * info.pixelAspect.toDouble());
    }
    _storedSize       = CGSizeMake(width, height);
    _presentationSize = media::SwapsAxes(_orientation) ? CGSizeMake(height, width) : _storedSize;

    std::int64_t earliest = std::numeric_limits<std::int64_t>::max();
    for (const media::Sample& sample : samples) earliest = std::min(earliest, sample.pts);
    const std::int64_t end = info.contentEndTicks;
    _first                 = NsTime(samples.empty() ? 0 : earliest);
    _duration              = NsTime(std::max<std::int64_t>(0, samples.empty() ? 0 : end - earliest));
    _frames                = static_cast<NSInteger>(samples.size());
    _frameRate             = info.minFramePeriod.valid() && info.minFramePeriod.numerator > 0 ? 1.0 / info.minFramePeriod.toDouble() : 0;

    NSMutableArray<NSString*>* warnings = [NSMutableArray array];
    for (const std::string& warning : _reader->warnings()) {
        NSString* text = [NSString stringWithUTF8String:warning.c_str()];
        [warnings addObject:text != nil ? text : @""];
    }
    _warnings = warnings;

    // The audio: the first enabled audio track this project reads.
    _hasAudioTrack = false;
    for (std::size_t index = 0; index < _reader->tracks().size(); ++index) {
        const media::MatroskaTrack& candidate = _reader->tracks()[index];
        if (candidate.type != media::MatroskaTrackType::Audio || ! candidate.enabled) continue;
        _hasAudioTrack = true;
        _audioTrack    = index;
        _audioName     = AudioCodecName(candidate.codec);
        if (! candidate.supported || _audioName == nil) {
            _audioWhy = [NSString stringWithUTF8String:(candidate.unsupportedReason.empty()
                                                           ? ("audio codec " + candidate.codecId + " is not played").c_str()
                                                           : candidate.unsupportedReason.c_str())];
        } else if (_reader->packets(index).empty()) {
            _audioWhy = @"the audio track has no packets";
        } else if (candidate.codec == media::MatroskaCodec::Opus &&
                   (candidate.codecPrivate.size() < 19 || candidate.codecPrivate[18] != 0 || candidate.codecPrivate[9] > 2)) {
            _audioWhy = @"Opus audio with more than two channels is not played";
        } else if (candidate.codec != media::MatroskaCodec::Opus && candidate.codec != media::MatroskaCodec::Vorbis &&
                   candidate.channels > 2) {
            _audioWhy = [NSString stringWithFormat:@"%@ audio with %u channels is not played", _audioName, candidate.channels];
        } else {
            _audioPlayable = YES;
        }
        break;
    }
    return YES;
}

- (NSString*)containerName { return _containerName; }
- (NSString*)videoCodecName { return _videoCodecName; }
- (CMVideoFormatDescriptionRef)videoFormatDescription { return static_cast<CMVideoFormatDescriptionRef>(_format.description.get()); }
- (CGSize)codedSize { return _codedSize; }
- (CGSize)presentationSize { return _presentationSize; }
- (NSInteger)bitDepth { return _format.bitDepth; }
- (CMTime)firstPresentationTime { return _first; }
- (CMTime)duration { return _duration; }
- (NSInteger)frameCount { return _frames; }
- (double)nominalFrameRate { return _frameRate; }
- (NSArray<NSString*>*)warnings { return _warnings; }
- (BOOL)transformSwapsAxes { return media::SwapsAxes(_orientation); }
// The matrix is written for a y-down picture; a y-up layer sees the same turn the other way
// round, so the off-diagonal terms change sign.
- (CGAffineTransform)layerTransform
{
    const CGAffineTransform linear = LinearTransform(_orientation);
    return CGAffineTransformMake(linear.a, -linear.b, -linear.c, linear.d, 0, 0);
}
- (CGAffineTransform)preferredTransform { return Placed(LinearTransform(_orientation), _storedSize); }
- (BOOL)hasPlayableAudio { return _audioPlayable; }
- (NSString*)audioCodecName { return _hasAudioTrack ? _audioName : nil; }
- (NSString*)audioUnavailableReason { return _hasAudioTrack && ! _audioPlayable ? _audioWhy : nil; }

- (media::MatroskaReader&)matroska { return *_reader; }

- (WMWebMVideoReader*)makeVideoReader { return [[WMWebMVideoReader alloc] initWithFile:self]; }

- (WMWebMAudioReader*)makeAudioReaderWithError:(NSError**)error
{
    if (! _hasAudioTrack || ! _audioPlayable) {
        if (error != nullptr) *error = MakeError(WMWebMErrorUnsupportedFormat, _audioWhy != nil ? _audioWhy.UTF8String : "the file has no audio", _audioName);
        return nil;
    }
    std::string why;
    auto decoder = sound::OpenMatroskaAudio(_reader, _audioTrack, &why);
    if (decoder == nullptr) {
        if (error != nullptr) *error = MakeError(WMWebMErrorUnsupportedFormat, why, _audioName);
        return nil;
    }
    const auto& packets = _reader->packets(_audioTrack);
    return [[WMWebMAudioReader alloc] initWithFile:self decoder:std::move(decoder) startNs:packets.empty() ? 0 : packets.front().ptsNs];
}

- (CGImageRef)copyPosterImageAtTime:(CMTime)time
{
    @autoreleasepool {
        const auto key = _reader->findVideoKeyframeAtOrBefore(ToNs(time));
        if (! key) return nullptr;
        std::vector<std::uint8_t> bytes;
        media::Error              read;
        if (! _reader->readSample(*key, &bytes, &read)) return nullptr;
        const media::Sample&          sample = _reader->videoSamples()[*key];
        const media::VideoStreamInfo& info   = _reader->videoInfo();
        media::apple::StreamFormat    format;
        std::string                   why;
        const media::Vp9FrameHeader*   vp9 = _reader->vp9KeyFrame() ? &*_reader->vp9KeyFrame() : nullptr;
        if (! media::apple::MakeStreamFormat(info, vp9, bytes.data(), bytes.size(), &format, &why)) return nullptr;
        auto decoder = media::apple::VtFrameDecoder::Create(std::move(format), info.timescale, 0, {}, &why);
        if (decoder == nullptr) return nullptr;
        if (decoder->submit(bytes.data(), bytes.size(), { sample.pts, sample.dts, sample.duration }, true, &why) !=
                media::apple::VtFrameDecoder::SubmitResult::Accepted ||
            ! decoder->drain(&why)) {
            return nullptr;
        }
        media::apple::DecodedFrame frame;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
        for (;;) {
            const auto got = decoder->receive(&frame, std::chrono::milliseconds(100), &why);
            if (got == media::apple::VtFrameDecoder::ReceiveResult::Frame) break;
            if (got != media::apple::VtFrameDecoder::ReceiveResult::NotReady || std::chrono::steady_clock::now() > deadline) return nullptr;
        }
        CGImageRef image = nullptr;
        if (VTCreateCGImageFromCVPixelBuffer(static_cast<CVPixelBufferRef>(frame.pixels.get()), nullptr, &image) != noErr || image == nullptr) {
            return nullptr;
        }
        if (_orientation == media::Orientation::Identity && _storedSize.width == static_cast<CGFloat>(CGImageGetWidth(image)) &&
            _storedSize.height == static_cast<CGFloat>(CGImageGetHeight(image))) {
            return image;
        }
        // Upright and at the shown shape: the decoded picture in the file's orientation and pixel aspect.
        const CGSize         size = _presentationSize;
        CGColorSpaceRef      space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef         context = CGBitmapContextCreate(nullptr, static_cast<size_t>(size.width), static_cast<size_t>(size.height), 8, 0, space,
                                                              kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast);
        CGColorSpaceRelease(space);
        if (context == nullptr) return image;
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        // The transform is in the file's y-down convention: flip into it, apply it, flip the picture upright.
        CGContextTranslateCTM(context, 0, size.height);
        CGContextScaleCTM(context, 1, -1);
        CGContextConcatCTM(context, [self preferredTransform]);
        CGContextTranslateCTM(context, 0, _storedSize.height);
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, CGRectMake(0, 0, _storedSize.width, _storedSize.height), image);
        CGImageRef upright = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        CGImageRelease(image);
        return upright;
    }
}

@end

// MARK: - Video

@implementation WMWebMVideoReader {
    WMWebMFile*  _file;
    std::size_t  _next;
    CMTime       _offset;
    NSError*     _error;
    std::vector<std::uint8_t> _scratch;
}

- (instancetype)initWithFile:(WMWebMFile*)file
{
    if ((self = [super init])) {
        _file   = file;
        _offset = kCMTimeZero;
        [self seekToTime:kCMTimeNegativeInfinity];
    }
    return self;
}

- (CMTime)timeOffset { return _offset; }
- (void)setTimeOffset:(CMTime)offset { _offset = CMTIME_IS_NUMERIC(offset) ? offset : kCMTimeZero; }
- (NSError*)error { return _error; }
- (BOOL)atEnd { return _next >= [_file matroska].videoSamples().size(); }

- (CMTime)seekToTime:(CMTime)time
{
    const media::MatroskaReader& reader = [_file matroska];
    const std::int64_t target = CMTIME_IS_NEGATIVE_INFINITY(time) ? std::numeric_limits<std::int64_t>::min() : ToNs(time);
    const auto key = reader.findVideoKeyframeAtOrBefore(target);
    _next  = key.value_or(reader.videoSamples().size());
    _error = nil;
    return key ? NsTime(reader.videoSamples()[*key].pts) : kCMTimeInvalid;
}

- (CMSampleBufferRef)copyNextSampleBuffer
{
    const media::MatroskaReader& reader = [_file matroska];
    const auto&                  samples = reader.videoSamples();
    const auto&                  packets = reader.packets(reader.videoTrackIndex());
    const std::int64_t           offset  = ToNs(_offset);
    while (_next < samples.size()) {
        const std::size_t   index  = _next;
        const media::Sample& sample = samples[index];
        media::Error read;
        if (! reader.readSample(index, &_scratch, &read)) {
            _error = MakeError(WMWebMErrorUnreadable, media::Describe(read));
            return nullptr;
        }
        ++_next;
        if (_scratch.empty()) continue;

        CMBlockBufferRef block = nullptr;
        if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, _scratch.size(), kCFAllocatorDefault, nullptr, 0, _scratch.size(),
                                               kCMBlockBufferAssureMemoryNowFlag, &block) != noErr || block == nullptr) {
            _error = MakeError(WMWebMErrorUnreadable, "a frame's memory could not be allocated");
            return nullptr;
        }
        if (CMBlockBufferReplaceDataBytes(_scratch.data(), block, 0, _scratch.size()) != noErr) {
            CFRelease(block);
            _error = MakeError(WMWebMErrorUnreadable, "a frame's bytes could not be copied");
            return nullptr;
        }
        CMSampleTimingInfo timing {};
        timing.duration              = NsTime(std::max<std::int64_t>(sample.duration, 0));
        timing.presentationTimeStamp = NsTime(sample.pts + offset);
        timing.decodeTimeStamp       = NsTime(sample.dts + offset);
        const std::size_t sampleSize = _scratch.size();
        CMSampleBufferRef buffer     = nullptr;
        const OSStatus status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, [_file videoFormatDescription], 1, 1, &timing, 1,
                                                          &sampleSize, &buffer);
        CFRelease(block);
        if (status != noErr || buffer == nullptr) {
            _error = MakeError(WMWebMErrorDamaged, "a frame's sample buffer could not be made");
            return nullptr;
        }
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, true);
        if (attachments != nullptr && CFArrayGetCount(attachments) > 0) {
            auto* dictionary = const_cast<CFMutableDictionaryRef>(static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0)));
            if (! sample.sync) {
                CFDictionarySetValue(dictionary, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
                CFDictionarySetValue(dictionary, kCMSampleAttachmentKey_DependsOnOthers, kCFBooleanTrue);
            }
            if (index < packets.size() && packets[index].invisible) CFDictionarySetValue(dictionary, kCMSampleAttachmentKey_DoNotDisplay, kCFBooleanTrue);
        }
        return buffer;
    }
    return nullptr;
}

@end

// MARK: - Audio

@implementation WMWebMAudioReader {
    WMWebMFile*                  _file;
    std::unique_ptr<sound::PcmDecoder> _decoder;
    sound::PcmFormat             _format;
    CMAudioFormatDescriptionRef  _description;
    std::int64_t                 _startNs;
    std::int64_t                 _offsetNs;
    std::uint64_t                _frames;
    std::uint64_t                _limitFrames;
    bool                         _ended;
    NSError*                     _error;
    std::vector<float>           _samples;
}

- (instancetype)initWithFile:(WMWebMFile*)file decoder:(std::unique_ptr<sound::PcmDecoder>)decoder startNs:(std::int64_t)startNs
{
    if ((self = [super init])) {
        _file    = file;
        _decoder = std::move(decoder);
        _format  = _decoder->format();
        _startNs = startNs;
        _limitFrames = std::numeric_limits<std::uint64_t>::max();
        AudioStreamBasicDescription asbd {};
        asbd.mSampleRate       = _format.sampleRate;
        asbd.mFormatID         = kAudioFormatLinearPCM;
        asbd.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        asbd.mChannelsPerFrame = _format.channels;
        asbd.mBitsPerChannel   = 32;
        asbd.mBytesPerFrame    = 4 * _format.channels;
        asbd.mFramesPerPacket  = 1;
        asbd.mBytesPerPacket   = asbd.mBytesPerFrame;
        if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, nullptr, 0, nullptr, nullptr, &_description) != noErr) return nil;
        _samples.resize(static_cast<std::size_t>(_format.sampleRate / 10) * _format.channels);
    }
    return self;
}

- (void)dealloc
{
    if (_description != nullptr) CFRelease(_description);
}

- (double)sampleRate { return _format.sampleRate; }
- (NSInteger)channelCount { return _format.channels; }
- (CMAudioFormatDescriptionRef)formatDescription { return _description; }
- (CMTime)startTime { return NsTime(_startNs); }
- (CMTime)timeOffset { return NsTime(_offsetNs); }
- (BOOL)atEnd { return _ended; }
- (NSError*)error { return _error; }

- (void)rewindWithTimeOffset:(CMTime)offset limit:(CMTime)limit
{
    _offsetNs = ToNs(offset);
    _frames   = 0;
    _ended    = false;
    _error    = nil;
    _limitFrames = CMTIME_IS_NUMERIC(limit) && ToNs(limit) > 0
        ? static_cast<std::uint64_t>(static_cast<double>(ToNs(limit)) * _format.sampleRate / 1e9)
        : std::numeric_limits<std::uint64_t>::max();
    if (! _decoder->rewind()) {
        _ended = true;
        _error = MakeError(WMWebMErrorDamaged, _decoder->failure().empty() ? "the audio could not be restarted" : _decoder->failure());
    }
}

- (CMSampleBufferRef)copyNextSampleBuffer
{
    if (_ended || _frames >= _limitFrames) {
        _ended = true;
        return nullptr;
    }
    const std::size_t channels = _format.channels;
    std::size_t want = _samples.size() / channels;
    want = static_cast<std::size_t>(std::min<std::uint64_t>(want, _limitFrames - _frames));
    const std::size_t got = _decoder->read(_samples.data(), want);
    if (got == 0) {
        _ended = true;
        if (_decoder->failed()) _error = MakeError(WMWebMErrorDamaged, _decoder->failure());
        return nullptr;
    }
    const std::size_t bytes = got * channels * sizeof(float);
    CMBlockBufferRef block = nullptr;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, bytes, kCFAllocatorDefault, nullptr, 0, bytes,
                                           kCMBlockBufferAssureMemoryNowFlag, &block) != noErr || block == nullptr) {
        _ended = true;
        return nullptr;
    }
    if (CMBlockBufferReplaceDataBytes(_samples.data(), block, 0, bytes) != noErr) {
        CFRelease(block);
        _ended = true;
        return nullptr;
    }
    // Frame positions are exact integers; the time in nanoseconds follows from them.
    const std::int64_t ns = _startNs + _offsetNs + static_cast<std::int64_t>(_frames * 1000000000ULL / static_cast<std::uint64_t>(_format.sampleRate));
    CMSampleBufferRef buffer = nullptr;
    const OSStatus status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, _description, static_cast<CMItemCount>(got),
                                                                                  NsTime(ns), nullptr, &buffer);
    CFRelease(block);
    _frames += got;
    if (status != noErr || buffer == nullptr) {
        _ended = true;
        return nullptr;
    }
    return buffer;
}

@end
