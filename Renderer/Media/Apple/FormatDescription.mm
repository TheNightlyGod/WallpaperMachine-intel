#include "Media/Apple/FormatDescription.hpp"

#include "Media/Av1/Av1SequenceHeader.hpp"
#include "Media/ByteReader.hpp"

#import <CoreFoundation/CoreFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <mutex>
#include <vector>

namespace wallpaper::media::apple
{

FormatDescription& FormatDescription::operator=(FormatDescription&& other) noexcept
{
    if (this != &other) {
        if (m_ref != nullptr) CFRelease(m_ref);
        m_ref       = other.m_ref;
        other.m_ref = nullptr;
    }
    return *this;
}

FormatDescription::~FormatDescription()
{
    if (m_ref != nullptr) CFRelease(m_ref);
}

namespace
{

constexpr std::uint32_t kAvcC = FourCC('a', 'v', 'c', 'C');
constexpr std::uint32_t kHvcC = FourCC('h', 'v', 'c', 'C');
constexpr std::uint32_t kAv1C = FourCC('a', 'v', '1', 'C');
constexpr std::uint32_t kVpcC = FourCC('v', 'p', 'c', 'C');

bool Refuse(std::string* whyNot, const std::string& reason)
{
    if (whyNot != nullptr) *whyNot = std::string(kFormatNotSupported) + reason;
    return false;
}

bool Broken(std::string* whyNot, const std::string& reason)
{
    if (whyNot != nullptr) *whyNot = reason;
    return false;
}

// --- Chroma layout from configuration records ------------------------------------

bool AvcProfileHasChromaExtension(std::uint8_t profile)
{
    switch (profile) {
    case 100: case 110: case 122: case 144: case 244: case 44: case 83: case 86:
    case 118: case 128: case 138: case 139: case 134: case 135: return true;
    default: return false;
    }
}

ChromaSubsampling FromChromaFormatIdc(unsigned idc)
{
    switch (idc) {
    case 0: return ChromaSubsampling::Monochrome;
    case 1: return ChromaSubsampling::Yuv420;
    case 2: return ChromaSubsampling::Yuv422;
    case 3: return ChromaSubsampling::Yuv444;
    default: return ChromaSubsampling::Unknown;
    }
}

ChromaSubsampling AvcChroma(const std::vector<std::uint8_t>& config)
{
    ByteReader reader(config.data(), config.size());
    reader.U8();
    const std::uint8_t profile = reader.U8();
    reader.Skip(3);
    const std::uint8_t spsCount = reader.U8() & 0x1FU;
    for (std::uint8_t index = 0; index < spsCount && reader.ok(); ++index) reader.Skip(reader.U16());
    const std::uint8_t ppsCount = reader.U8();
    for (std::uint8_t index = 0; index < ppsCount && reader.ok(); ++index) reader.Skip(reader.U16());
    if (! reader.ok()) return ChromaSubsampling::Unknown;
    if (AvcProfileHasChromaExtension(profile) && reader.remaining() >= 3) {
        return FromChromaFormatIdc(reader.U8() & 0x03U);
    }
    // Profiles without the extension are 4:2:0 by definition.
    return ChromaSubsampling::Yuv420;
}

ChromaSubsampling HvcChroma(const std::vector<std::uint8_t>& config)
{
    if (config.size() < 23) return ChromaSubsampling::Unknown;
    return FromChromaFormatIdc(config[16] & 0x03U);
}

ChromaSubsampling Av1Chroma(const std::vector<std::uint8_t>& config)
{
    if (config.size() < 4) return ChromaSubsampling::Unknown;
    if ((config[2] & 0x08U) != 0) return ChromaSubsampling::Monochrome;
    const bool x = (config[2] & 0x04U) != 0;
    const bool y = (config[2] & 0x02U) != 0;
    if (x && y) return ChromaSubsampling::Yuv420;
    if (x && ! y) return ChromaSubsampling::Yuv422;
    if (! x && ! y) return ChromaSubsampling::Yuv444;
    return ChromaSubsampling::Unknown;
}

ChromaSubsampling VpcChroma(const std::vector<std::uint8_t>& config)
{
    if (config.size() < 12 || config[0] != 1) return ChromaSubsampling::Unknown;
    switch ((config[6] >> 1) & 0x07U) {
    case 0: case 1: return ChromaSubsampling::Yuv420;
    case 2: return ChromaSubsampling::Yuv422;
    case 3: return ChromaSubsampling::Yuv444;
    default: return ChromaSubsampling::Unknown;
    }
}

// --- Range the stream states about itself -----------------------------------------

/// Whether the H.264 or HEVC parameter sets in `description` say the samples are
/// full range (the VUI's video_full_range_flag). Core Media reads the VUI when it
/// builds a description from parameter sets, so a description made from the
/// container's record (which keeps the sets as raw atoms) is rebuilt from them
/// and asked.
bool ParameterSetsStateFullRange(CMVideoFormatDescriptionRef description, CMVideoCodecType codec)
{
    auto stated = [](CMFormatDescriptionRef candidate) -> bool {
        CFTypeRef value = CMFormatDescriptionGetExtension(candidate, kCMFormatDescriptionExtension_FullRangeVideo);
        if (value == nullptr) return false;
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) return CFBooleanGetValue(static_cast<CFBooleanRef>(value)) != 0;
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            int number = 0;
            return CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberIntType, &number) && number != 0;
        }
        return false;
    };
    if (stated(description)) return true;

    const bool hevc = codec == kCMVideoCodecType_HEVC;
    size_t     count = 0;
    int        lengthSize = 0;
    const std::uint8_t* pointer = nullptr;
    size_t              size    = 0;
    auto get = [&](size_t index) {
        return hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(description, index, &pointer, &size, &count, &lengthSize)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, index, &pointer, &size, &count, &lengthSize);
    };
    if (get(0) != noErr || count == 0 || count > 16) return false;
    std::vector<const std::uint8_t*> pointers;
    std::vector<size_t>              sizes;
    for (size_t index = 0; index < count; ++index) {
        if (get(index) != noErr) return false;
        pointers.push_back(pointer);
        sizes.push_back(size);
    }
    CMVideoFormatDescriptionRef rebuilt = nullptr;
    const OSStatus status = hevc ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                       kCFAllocatorDefault, count, pointers.data(), sizes.data(), lengthSize, nullptr, &rebuilt)
                                 : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                       kCFAllocatorDefault, count, pointers.data(), sizes.data(), lengthSize, &rebuilt);
    if (status != noErr || rebuilt == nullptr) return false;
    const bool full = stated(rebuilt);
    CFRelease(rebuilt);
    return full;
}

/// The range an AV1 stream states in its sequence header: in the record's
/// configOBUs, else in the first sample (a temporal unit).
bool Av1StatesFullRange(const VideoStreamInfo& info, const std::uint8_t* firstSample, std::size_t firstSampleSize)
{
    Av1SequenceColour colour;
    if (info.codecConfig.size() > 4 && ReadAv1SequenceColour(info.codecConfig.data() + 4, info.codecConfig.size() - 4, &colour)) {
        return colour.fullRange;
    }
    if (firstSample != nullptr && firstSampleSize > 0 && ReadAv1SequenceColour(firstSample, firstSampleSize, &colour)) {
        return colour.fullRange;
    }
    return false;
}

// --- Colour ---------------------------------------------------------------------

CFStringRef PrimariesString(std::uint16_t code)
{
    switch (code) {
    case 1: return kCMFormatDescriptionColorPrimaries_ITU_R_709_2;
    case 5: return kCMFormatDescriptionColorPrimaries_EBU_3213;
    case 6: case 7: return kCMFormatDescriptionColorPrimaries_SMPTE_C;
    case 9: return kCMFormatDescriptionColorPrimaries_ITU_R_2020;
    case 11: return kCMFormatDescriptionColorPrimaries_DCI_P3;
    case 12: return kCMFormatDescriptionColorPrimaries_P3_D65;
    default: return nullptr;
    }
}

CFStringRef TransferString(std::uint16_t code)
{
    switch (code) {
    case 1: case 6: case 14: case 15: return kCMFormatDescriptionTransferFunction_ITU_R_709_2;
    case 7: return kCMFormatDescriptionTransferFunction_SMPTE_240M_1995;
    case 8: return kCMFormatDescriptionTransferFunction_Linear;
    case 16: return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ;
    case 18: return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG;
    default: return nullptr;
    }
}

CFStringRef MatrixString(std::uint16_t code)
{
    switch (code) {
    case 1: return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2;
    case 5: case 6: return kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4;
    case 7: return kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995;
    case 9: case 10: return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020;
    default: return nullptr;
    }
}

/// The colour a VP9 header's color_space code names, as H.273 codes.
ColourDescription ColourFromVp9(const Vp9FrameHeader& header)
{
    ColourDescription colour;
    colour.source    = ColourDescription::Source::CodecConfig;
    colour.fullRange = header.fullRange;
    switch (header.colourSpace) {
    case 1: colour.primaries = 5; colour.transfer = 6; colour.matrix = 5; break;   // BT.601
    case 2: colour.primaries = 1; colour.transfer = 1; colour.matrix = 1; break;   // BT.709
    case 3: colour.primaries = 6; colour.transfer = 6; colour.matrix = 6; break;   // SMPTE-170
    case 4: colour.primaries = 7; colour.transfer = 7; colour.matrix = 7; break;   // SMPTE-240
    case 5: colour.primaries = 9; colour.transfer = 14; colour.matrix = 9; break;  // BT.2020
    case 7: colour.primaries = 1; colour.transfer = 13; colour.matrix = 0; break;  // sRGB
    default: colour.source = ColourDescription::Source::None; break;
    }
    return colour;
}

/// The colour the stream declares, if it declares any: the container's, else the
/// configuration record's, else the VP9 header's.
ColourDescription ColourOf(const VideoStreamInfo& info, const Vp9FrameHeader* vp9)
{
    if (info.colour.present()) return info.colour;
    if (vp9 != nullptr && vp9->hasColourConfig) return ColourFromVp9(*vp9);
    return ColourDescription {};
}

void AddColourExtensions(NSMutableDictionary* extensions, const ColourDescription& colour)
{
    if (! colour.present()) return;
    if (CFStringRef primaries = PrimariesString(colour.primaries)) {
        extensions[(__bridge NSString*)kCMFormatDescriptionExtension_ColorPrimaries] = (__bridge NSString*)primaries;
    }
    if (CFStringRef transfer = TransferString(colour.transfer)) {
        extensions[(__bridge NSString*)kCMFormatDescriptionExtension_TransferFunction] = (__bridge NSString*)transfer;
    }
    if (CFStringRef matrix = MatrixString(colour.matrix)) {
        extensions[(__bridge NSString*)kCMFormatDescriptionExtension_YCbCrMatrix] = (__bridge NSString*)matrix;
    }
    if (colour.fullRange) extensions[(__bridge NSString*)kCMFormatDescriptionExtension_FullRangeVideo] = @YES;
}

// --- vpcC ------------------------------------------------------------------------

/// A level that covers `width x height`; WebM does not state one and the decoder only needs a plausible value.
std::uint8_t Vp9LevelFor(std::uint32_t width, std::uint32_t height)
{
    const std::uint64_t samples = static_cast<std::uint64_t>(width) * height;
    if (samples <= 2228224) return 41;
    if (samples <= 8912896) return 51;
    return 62;
}

std::vector<std::uint8_t> SynthesizeVpcC(const VideoStreamInfo& info, const Vp9FrameHeader& header,
                                         const ColourDescription& colour)
{
    std::uint8_t chroma = 1;  // 4:2:0, co-located with luma
    if (header.subsamplingX == 1 && header.subsamplingY == 0) chroma = 2;
    else if (header.subsamplingX == 0 && header.subsamplingY == 0) chroma = 3;
    const std::uint32_t width  = header.width != 0 ? header.width : info.codedWidth;
    const std::uint32_t height = header.height != 0 ? header.height : info.codedHeight;
    return {
        1, 0, 0, 0,  // version 1, flags 0
        header.profile,
        Vp9LevelFor(width, height),
        static_cast<std::uint8_t>((header.bitDepth << 4) | (chroma << 1) | (colour.fullRange ? 1 : 0)),
        static_cast<std::uint8_t>(colour.present() ? colour.primaries : 2),
        static_cast<std::uint8_t>(colour.present() ? colour.transfer : 2),
        static_cast<std::uint8_t>(colour.present() ? colour.matrix : 2),
        0, 0,  // no codec initialization data
    };
}

// --- In-band parameter sets ----------------------------------------------------

struct NalUnit {
    const std::uint8_t* data;
    std::size_t         size;
};

/// The NAL units of a length-prefixed sample (`lengthSize` bytes of big-endian size before each).
std::vector<NalUnit> NalUnitsOf(const std::uint8_t* sample, std::size_t size, unsigned lengthSize)
{
    std::vector<NalUnit> units;
    if (lengthSize < 1 || lengthSize > 4) return units;
    std::size_t at = 0;
    while (at + lengthSize <= size) {
        std::size_t length = 0;
        for (unsigned index = 0; index < lengthSize; ++index) length = (length << 8) | sample[at + index];
        at += lengthSize;
        if (length == 0 || length > size - at) break;
        units.push_back({ sample + at, length });
        at += length;
    }
    return units;
}

/// Whether the avcC record lists no sequence parameter set.
bool AvcCWithoutParameterSets(const std::vector<std::uint8_t>& config)
{
    return config.size() < 7 || (config[5] & 0x1FU) == 0;
}

/// Whether the hvcC record lists no parameter-set array.
bool HvcCWithoutParameterSets(const std::vector<std::uint8_t>& config)
{
    return config.size() < 23 || config[22] == 0;
}

// --- Pixel format ----------------------------------------------------------------

std::uint32_t PixelFormatFor(std::uint8_t bitDepth, bool fullRange)
{
    if (bitDepth == 10) {
        return fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                         : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    }
    return fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                     : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
}

/// Takes over the one retained reference `ref` carries.
FormatDescription Adopt(CMVideoFormatDescriptionRef ref)
{
    return FormatDescription(const_cast<void*>(static_cast<const void*>(ref)));
}

NSData* DataOf(const std::vector<std::uint8_t>& bytes)
{
    return [NSData dataWithBytes:bytes.data() length:bytes.size()];
}

FormatDescription Create(CMVideoCodecType codec, const VideoStreamInfo& info, NSDictionary* extensions)
{
    CMVideoFormatDescriptionRef description = nullptr;
    const OSStatus status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, codec, static_cast<int32_t>(info.codedWidth), static_cast<int32_t>(info.codedHeight),
        (__bridge CFDictionaryRef)extensions, &description);
    if (status != noErr || description == nullptr) return {};
    return Adopt(description);
}

} // namespace

ChromaSubsampling ChromaSubsamplingOf(const VideoStreamInfo& info, const Vp9FrameHeader* vp9)
{
    switch (info.configFourcc) {
    case kAvcC: return AvcChroma(info.codecConfig);
    case kHvcC: return HvcChroma(info.codecConfig);
    case kAv1C: return Av1Chroma(info.codecConfig);
    case kVpcC: return VpcChroma(info.codecConfig);
    default: break;
    }
    if (vp9 != nullptr && vp9->hasColourConfig) {
        if (vp9->subsamplingX == 1 && vp9->subsamplingY == 1) return ChromaSubsampling::Yuv420;
        if (vp9->subsamplingX == 1 && vp9->subsamplingY == 0) return ChromaSubsampling::Yuv422;
        if (vp9->subsamplingX == 0 && vp9->subsamplingY == 0) return ChromaSubsampling::Yuv444;
    }
    return ChromaSubsampling::Unknown;
}

bool MakeStreamFormat(const VideoStreamInfo& info, const Vp9FrameHeader* vp9, const std::uint8_t* firstSample,
                      std::size_t firstSampleSize, StreamFormat* out, std::string* whyNot)
{
    if (out == nullptr) return Broken(whyNot, "no output");
    *out = StreamFormat {};
    if (info.codedWidth == 0 || info.codedHeight == 0 || info.codedWidth > 65535 || info.codedHeight > 65535) {
        return Broken(whyNot, "the video has no usable picture size");
    }

    @autoreleasepool {
        CMVideoCodecType codec = 0;
        std::vector<std::uint8_t> vpcC;
        const std::uint32_t fourcc = info.codecFourcc;
        switch (fourcc) {
        case FourCC('a', 'v', 'c', '1'): case FourCC('a', 'v', 'c', '3'): codec = kCMVideoCodecType_H264; break;
        case FourCC('h', 'v', 'c', '1'): case FourCC('h', 'e', 'v', '1'): codec = kCMVideoCodecType_HEVC; break;
        case FourCC('a', 'v', '0', '1'): codec = kCMVideoCodecType_AV1; break;
        case FourCC('v', 'p', '0', '9'): codec = kCMVideoCodecType_VP9; break;
        case FourCC('v', 'p', '0', '8'): return Refuse(whyNot, "VP8 video");
        default: return Refuse(whyNot, "video codec '" + FourCCString(fourcc) + "'");
        }

        const ChromaSubsampling chroma = ChromaSubsamplingOf(info, vp9);
        if (chroma == ChromaSubsampling::Yuv422 || chroma == ChromaSubsampling::Yuv444) {
            return Refuse(whyNot, std::string(chroma == ChromaSubsampling::Yuv422 ? "4:2:2" : "4:4:4") +
                                      " chroma video");
        }

        std::uint8_t bitDepth = info.bitDepth;
        if (bitDepth == 0 && vp9 != nullptr && vp9->hasColourConfig) bitDepth = vp9->bitDepth;
        if (bitDepth == 0) bitDepth = 8;
        if (bitDepth != 8 && bitDepth != 10) return Refuse(whyNot, std::to_string(bitDepth) + "-bit video");

        if (codec == kCMVideoCodecType_VP9) {
            // VP9 comes from a supplemental decoder that has to be registered once.
            static std::once_flag registered;
            std::call_once(registered, [] { VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9); });
            if (! VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)) {
                return Refuse(whyNot, "VP9 video has no decoder on this Mac");
            }
        } else if (codec == kCMVideoCodecType_AV1) {
            // Only hardware decoding: a software AV1 decoder would be a cost the
            // wallpaper never agreed to.
            if (! VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
                return Refuse(whyNot, "AV1 video needs a Mac with an AV1 hardware decoder (M3 or later)");
            }
        }

        const ColourDescription colour = ColourOf(info, vp9);
        NSMutableDictionary* extensions = [NSMutableDictionary dictionary];
        AddColourExtensions(extensions, colour);

        FormatDescription description;
        const NSString* atomsKey = (__bridge NSString*)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms;
        switch (codec) {
        case kCMVideoCodecType_H264: {
            if (info.configFourcc != kAvcC || info.codecConfig.size() < 7) {
                return Broken(whyNot, "the H.264 stream has no usable avcC record");
            }
            if (AvcCWithoutParameterSets(info.codecConfig)) {
                // avc3: parameter sets travel in the first key frame.
                const unsigned lengthSize = (info.codecConfig[4] & 0x03U) + 1U;
                std::vector<const std::uint8_t*> pointers;
                std::vector<std::size_t>         sizes;
                for (const NalUnit& unit : NalUnitsOf(firstSample, firstSampleSize, lengthSize)) {
                    const unsigned type = unit.data[0] & 0x1FU;
                    if (type == 7 || type == 8) {
                        pointers.push_back(unit.data);
                        sizes.push_back(unit.size);
                    }
                }
                const bool haveSps = std::any_of(pointers.begin(), pointers.end(),
                                                 [](const std::uint8_t* p) { return (p[0] & 0x1FU) == 7; });
                if (! haveSps) return Broken(whyNot, "the H.264 stream carries no parameter sets, in its record or its first key frame");
                CMVideoFormatDescriptionRef created = nullptr;
                if (CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        kCFAllocatorDefault, pointers.size(), pointers.data(), sizes.data(),
                        static_cast<int>(lengthSize), &created) != noErr ||
                    created == nullptr) {
                    return Broken(whyNot, "the H.264 parameter sets in the first key frame were refused");
                }
                description = Adopt(created);
                break;
            }
            extensions[atomsKey] = @{ @"avcC" : DataOf(info.codecConfig) };
            description = Create(codec, info, extensions);
            break;
        }
        case kCMVideoCodecType_HEVC: {
            if (info.configFourcc != kHvcC || info.codecConfig.size() < 23) {
                return Broken(whyNot, "the HEVC stream has no usable hvcC record");
            }
            if (HvcCWithoutParameterSets(info.codecConfig)) {
                // hev1: parameter sets travel in the first key frame.
                const unsigned lengthSize = (info.codecConfig[21] & 0x03U) + 1U;
                std::vector<const std::uint8_t*> pointers;
                std::vector<std::size_t>         sizes;
                for (const NalUnit& unit : NalUnitsOf(firstSample, firstSampleSize, lengthSize)) {
                    const unsigned type = (unit.data[0] >> 1) & 0x3FU;
                    if (type == 32 || type == 33 || type == 34) {
                        pointers.push_back(unit.data);
                        sizes.push_back(unit.size);
                    }
                }
                const bool haveSps = std::any_of(pointers.begin(), pointers.end(), [](const std::uint8_t* p) {
                    return ((p[0] >> 1) & 0x3FU) == 33;
                });
                if (! haveSps) return Broken(whyNot, "the HEVC stream carries no parameter sets, in its record or its first key frame");
                CMVideoFormatDescriptionRef created = nullptr;
                if (CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        kCFAllocatorDefault, pointers.size(), pointers.data(), sizes.data(),
                        static_cast<int>(lengthSize), (__bridge CFDictionaryRef)extensions, &created) != noErr ||
                    created == nullptr) {
                    return Broken(whyNot, "the HEVC parameter sets in the first key frame were refused");
                }
                description = Adopt(created);
                break;
            }
            extensions[atomsKey] = @{ @"hvcC" : DataOf(info.codecConfig) };
            description = Create(codec, info, extensions);
            break;
        }
        case kCMVideoCodecType_AV1: {
            if (info.configFourcc != kAv1C || info.codecConfig.size() < 4) {
                return Broken(whyNot, "the AV1 stream has no usable av1C record");
            }
            extensions[atomsKey] = @{ @"av1C" : DataOf(info.codecConfig) };
            description = Create(codec, info, extensions);
            break;
        }
        case kCMVideoCodecType_VP9: {
            if (info.configFourcc == kVpcC && ! info.codecConfig.empty()) {
                vpcC = info.codecConfig;
            } else if (vp9 != nullptr && vp9->hasColourConfig) {
                vpcC = SynthesizeVpcC(info, *vp9, colour);
            } else {
                return Broken(whyNot, "the VP9 stream's profile and colour could not be read from its first key frame");
            }
            extensions[atomsKey] = @{ @"vpcC" : DataOf(vpcC) };
            description = Create(codec, info, extensions);
            break;
        }
        default: break;
        }
        if (! description) return Broken(whyNot, "Core Media refused the stream's codec description");

        out->description = std::move(description);
        out->codecType   = codec;
        out->bitDepth    = bitDepth;
        // The container's colour wins; with none the stream's own parameter sets or
        // sequence header say. Asking for video range on a full-range stream would
        // have VideoToolbox squeeze 0-255 into 16-235 (VP9 states it in the colour
        // already taken from the record or the key frame header).
        bool fullRange = colour.present() && colour.fullRange;
        if (! colour.present()) {
            if (codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC) {
                fullRange = ParameterSetsStateFullRange(static_cast<CMVideoFormatDescriptionRef>(out->description.get()), codec);
            } else if (codec == kCMVideoCodecType_AV1) {
                fullRange = Av1StatesFullRange(info, firstSample, firstSampleSize);
            }
        }
        out->fullRange   = fullRange;
        out->pixelFormat = PixelFormatFor(bitDepth, out->fullRange);
    }
    return true;
}

} // namespace wallpaper::media::apple
