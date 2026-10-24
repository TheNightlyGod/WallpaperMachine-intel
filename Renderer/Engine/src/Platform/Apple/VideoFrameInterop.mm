// Clean-room implementation from the WallpaperMachine spec e5-text-audio-video-runtime.md; written without access to the original source.
#include "Platform/Apple/VideoFrameInterop.hpp"
#include "Utils/Logging.h"

#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>

#include <algorithm>
#include <cctype>
#include <mutex>
#include <sstream>
#include <unordered_map>
#include <utility>
#include <vector>

namespace wallpaper::video
{
namespace
{

/// The bytes of a CFData attachment, or empty when it is absent or not data.
/// Mastering display and content light level arrive as the payload of the
/// matching HEVC SEI message: big-endian integers, no framing.
std::vector<uint8_t> CopyDataAttachment(CVPixelBufferRef pixel_buffer, CFStringRef key)
{
    CFTypeRef attachment = CVBufferCopyAttachment(pixel_buffer, key, nullptr);
    std::vector<uint8_t> bytes;
    if (attachment != nullptr && CFGetTypeID(attachment) == CFDataGetTypeID()) {
        const auto data = static_cast<CFDataRef>(attachment);
        const auto* begin = CFDataGetBytePtr(data);
        bytes.assign(begin, begin + CFDataGetLength(data));
    }
    if (attachment != nullptr) CFRelease(attachment);
    return bytes;
}

/// The brightest light a frame says it carries, in nits: the maximum content
/// light level (ST 2086's companion, CTA-861.3: two 16-bit values in nits) when
/// it is stated, else the mastering display's maximum luminance (24 bytes: three
/// primaries and a white point as 16-bit xy, then maximum and minimum luminance
/// as 32-bit values in units of 0.0001 nits). Zero when neither is there.
float PeakNitsOfPixelBuffer(CVPixelBufferRef pixel_buffer)
{
    const auto content = CopyDataAttachment(pixel_buffer, kCVImageBufferContentLightLevelInfoKey);
    if (content.size() >= 2) {
        const auto max_cll = static_cast<uint32_t>(content[0] << 8 | content[1]);
        if (max_cll > 0) return static_cast<float>(max_cll);
    }
    const auto mastering = CopyDataAttachment(pixel_buffer, kCVImageBufferMasteringDisplayColorVolumeKey);
    if (mastering.size() >= 20) {
        const uint32_t max_luminance = static_cast<uint32_t>(mastering[16]) << 24 |
                                       static_cast<uint32_t>(mastering[17]) << 16 |
                                       static_cast<uint32_t>(mastering[18]) << 8 |
                                       static_cast<uint32_t>(mastering[19]);
        if (max_luminance > 0) return static_cast<float>(max_luminance) / 10000.0f;
    }
    return 0.0f;
}

bool IsTenBitPixelFormat(OSType pixel_format)
{
    return pixel_format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
           pixel_format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
}

/// Colorimetry of a Core Video pixel buffer, which is what the hardware
/// decoder hands over. The pixel format decides the range and the bit depth; the
/// attachments, when present, decide the matrix, the transfer function, the
/// primaries and the peak.
YuvColorDescription ColorDescriptionForPixelBuffer(CVPixelBufferRef pixel_buffer,
                                                   OSType pixel_format,
                                                   uint32_t width,
                                                   uint32_t height)
{
    YuvColorDescription description {};
    description.range = pixel_format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                                pixel_format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        ? YuvRange::Full
        : YuvRange::Limited;
    // Transfer, primaries and peak matter only to the 10-bit conversion. An
    // 8-bit frame is never asked, which keeps what an 8-bit frame costs to
    // describe exactly what it was before 10-bit existed.
    const bool ten_bit = IsTenBitPixelFormat(pixel_format);
    if (ten_bit) description.bit_depth = 10;

    if (ten_bit) {
        CFTypeRef transfer_attachment =
            CVBufferCopyAttachment(pixel_buffer, kCVImageBufferTransferFunctionKey, nullptr);
        if (transfer_attachment != nullptr) {
            if (CFEqual(transfer_attachment, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)) {
                description.transfer = YuvTransfer::Pq;
            } else if (CFEqual(transfer_attachment, kCVImageBufferTransferFunction_ITU_R_2100_HLG)) {
                description.transfer = YuvTransfer::Hlg;
            }
            CFRelease(transfer_attachment);
        }
    }
    const bool hdr = description.transfer != YuvTransfer::Sdr;
    if (hdr) description.peak_nits = PeakNitsOfPixelBuffer(pixel_buffer);

    CFTypeRef matrix_attachment =
        CVBufferCopyAttachment(pixel_buffer, kCVImageBufferYCbCrMatrixKey, nullptr);
    if (matrix_attachment == nullptr) {
        description.matrix = InferYuvMatrix(width, height);
        description.matrix_inferred = true;
    } else {
        if (CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) {
            description.matrix = YuvMatrix::Bt709;
        } else if (CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_ITU_R_2020)) {
            description.matrix = YuvMatrix::Bt2020NonConstantLuminance;
        } else if (CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_ITU_R_601_4) ||
                   CFEqual(matrix_attachment, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995)) {
            description.matrix = YuvMatrix::Bt601;
        } else {
            description.matrix = InferYuvMatrix(width, height);
            description.matrix_inferred = true;
        }
        CFRelease(matrix_attachment);
    }

    if (!ten_bit) return description;

    CFTypeRef primaries_attachment =
        CVBufferCopyAttachment(pixel_buffer, kCVImageBufferColorPrimariesKey, nullptr);
    if (primaries_attachment != nullptr) {
        if (CFEqual(primaries_attachment, kCVImageBufferColorPrimaries_ITU_R_2020)) {
            description.primaries = ColorPrimaries::Bt2020;
        } else if (CFEqual(primaries_attachment, kCVImageBufferColorPrimaries_P3_D65)) {
            description.primaries = ColorPrimaries::P3D65;
        }
        CFRelease(primaries_attachment);
    } else if (hdr || description.matrix == YuvMatrix::Bt2020NonConstantLuminance) {
        // An HDR stream that names no primaries is BT.2020, and so is any 10-bit
        // picture that says its matrix is.
        description.primaries = ColorPrimaries::Bt2020;
    }
    // BT.2020's matrix is the one a PQ or HLG picture was made with. A frame
    // that carries the curve but names no matrix, or one that is inferred, would
    // otherwise come out with BT.709's, which is visibly wrong rather than
    // approximately right.
    if (hdr && description.matrix_inferred) description.matrix = YuvMatrix::Bt2020NonConstantLuminance;
    return description;
}
} // namespace

/// One line per distinct colorimetry so an inferred matrix is visible in the
/// log without printing anything per frame.
void ReportInferredColor(const YuvColorDescription& description)
{
    if (!description.matrix_inferred) return;
    static std::mutex mutex;
    static std::unordered_map<uint32_t, bool> reported;
    const uint32_t key = (static_cast<uint32_t>(description.matrix) << 8) |
        static_cast<uint32_t>(description.range);
    std::lock_guard lock(mutex);
    if (!reported.try_emplace(key, true).second) return;
    LOG_INFO("video color metadata missing or unsupported; using %s %s range",
             YuvMatrixName(description.matrix),
             YuvRangeName(description.range));
}

void ReportTenBitColor(const YuvColorDescription& description)
{
    static std::mutex mutex;
    static std::unordered_map<uint64_t, bool> reported;
    const uint64_t key = static_cast<uint64_t>(description.transfer) |
        static_cast<uint64_t>(description.primaries) << 4 |
        static_cast<uint64_t>(description.matrix) << 8 |
        static_cast<uint64_t>(description.range) << 12 |
        static_cast<uint64_t>(description.peak_nits) << 16;
    std::lock_guard lock(mutex);
    if (!reported.try_emplace(key, true).second) return;
    const char* transfer = description.transfer == YuvTransfer::Pq ? "PQ"
        : description.transfer == YuvTransfer::Hlg ? "HLG" : "SDR";
    const char* primaries = description.primaries == ColorPrimaries::Bt2020 ? "BT.2020"
        : description.primaries == ColorPrimaries::P3D65 ? "P3-D65" : "BT.709";
    if (description.transfer == YuvTransfer::Sdr) {
        LOG_INFO("10-bit video texture: %s, %s primaries, %s range, no tone map",
                 YuvMatrixName(description.matrix), primaries, YuvRangeName(description.range));
        return;
    }
    LOG_INFO("10-bit HDR video texture: %s %s, %s primaries, %s range, tone mapped to SDR from %.0f nits%s",
             transfer, YuvMatrixName(description.matrix), primaries, YuvRangeName(description.range),
             static_cast<double>(description.peak_nits > 0.0f ? description.peak_nits : kDefaultHdrPeakNits),
             description.peak_nits > 0.0f ? "" : " (assumed)");
}

bool AdoptPixelBufferAsVideoFrame(void* retained_pixel_buffer, VideoTextureFrame* out, std::string* error)
{
    if (retained_pixel_buffer == nullptr) {
        if (error != nullptr) *error = "the decoder returned a frame without a pixel buffer";
        return false;
    }
    if (out == nullptr) {
        CFRelease(retained_pixel_buffer);
        if (error != nullptr) *error = "video texture frame output must not be null";
        return false;
    }
    auto pixel_buffer = reinterpret_cast<CVPixelBufferRef>(retained_pixel_buffer);
    // The caller's +1 on the buffer now belongs to `out`; the surface needs a reference of its own.
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixel_buffer);
    if (surface != nullptr) CFRetain(surface);
    out->width        = static_cast<uint32_t>(CVPixelBufferGetWidth(pixel_buffer));
    out->height       = static_cast<uint32_t>(CVPixelBufferGetHeight(pixel_buffer));
    out->pixel_buffer = pixel_buffer;
    out->io_surface   = surface;
    out->pixel_format = static_cast<uint32_t>(CVPixelBufferGetPixelFormatType(pixel_buffer));
    out->plane_count  = CVPixelBufferIsPlanar(pixel_buffer)
        ? static_cast<uint32_t>(CVPixelBufferGetPlaneCount(pixel_buffer))
        : 1u;
    return true;
}

void ReleaseAppleVideoFrame(VideoTextureFrame* frame)
{
    if (frame == nullptr) return;
    // Taking each pointer out before releasing it makes a second call a no-op.
    if (void* surface = std::exchange(frame->io_surface, nullptr)) {
        CFRelease(reinterpret_cast<IOSurfaceRef>(surface));
    }
    if (void* buffer = std::exchange(frame->pixel_buffer, nullptr)) {
        CFRelease(reinterpret_cast<CVPixelBufferRef>(buffer));
    }
    frame->pixel_format = 0;
    frame->plane_count = 0;
}

void RetainAppleVideoFrame(const VideoTextureFrame& frame, VideoTextureFrame* out)
{
    if (out == nullptr) return;
    ReleaseAppleVideoFrame(out);
    *out = frame;
    if (out->io_surface != nullptr) {
        CFRetain(reinterpret_cast<IOSurfaceRef>(out->io_surface));
    }
    if (out->pixel_buffer != nullptr) {
        CFRetain(reinterpret_cast<CVPixelBufferRef>(out->pixel_buffer));
    }
}

YuvColorDescription AppleVideoFrameColorDescription(const VideoTextureFrame& frame)
{
    auto pixel_buffer = reinterpret_cast<CVPixelBufferRef>(frame.pixel_buffer);
    if (pixel_buffer == nullptr) return YuvColorDescription {};
    const YuvColorDescription description =
        ColorDescriptionForPixelBuffer(pixel_buffer,
                                       static_cast<OSType>(frame.pixel_format),
                                       frame.width,
                                       frame.height);
    ReportInferredColor(description);
    return description;
}

YuvColorParams AppleVideoFrameColorParams(const VideoTextureFrame& frame)
{
    return MakeYuvColorParams(AppleVideoFrameColorDescription(frame));
}

std::string DescribeAppleVideoFrame(const VideoTextureFrame& frame)
{
    std::ostringstream out;
    const uint32_t format = frame.pixel_format;
    out << "format " << format;
    const char four[5] {
        static_cast<char>((format >> 24) & 0xff), static_cast<char>((format >> 16) & 0xff),
        static_cast<char>((format >> 8) & 0xff), static_cast<char>(format & 0xff), 0
    };
    if (std::all_of(four, four + 4, [](char c) { return std::isprint(static_cast<unsigned char>(c)) != 0; })) {
        out << " '" << four << "'";
    }
    out << " " << frame.width << "x" << frame.height << " planes " << frame.plane_count;

    auto pixel_buffer = reinterpret_cast<CVPixelBufferRef>(frame.pixel_buffer);
    if (pixel_buffer == nullptr) {
        out << ": no pixel buffer";
        return out.str();
    }
    const CVReturn locked = CVPixelBufferLockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
    if (locked != kCVReturnSuccess) {
        out << ": lock failed " << locked;
        return out.str();
    }
    const bool planar = CVPixelBufferIsPlanar(pixel_buffer);
    const size_t planes = planar ? std::min<size_t>(CVPixelBufferGetPlaneCount(pixel_buffer), 3) : 1;
    for (size_t plane = 0; plane < planes; ++plane) {
        const auto* base = static_cast<const uint8_t*>(planar ? CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, plane)
                                                              : CVPixelBufferGetBaseAddress(pixel_buffer));
        const size_t width = planar ? CVPixelBufferGetWidthOfPlane(pixel_buffer, plane) : CVPixelBufferGetWidth(pixel_buffer);
        const size_t height = planar ? CVPixelBufferGetHeightOfPlane(pixel_buffer, plane) : CVPixelBufferGetHeight(pixel_buffer);
        const size_t pitch = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, plane) : CVPixelBufferGetBytesPerRow(pixel_buffer);
        if (base == nullptr || width == 0 || height == 0) {
            out << " | plane " << plane << " empty";
            continue;
        }
        const size_t bytes_per_pixel = std::max<size_t>(1, std::min<size_t>(4, pitch / width));
        const bool bgra = !planar && format == 'BGRA' && bytes_per_pixel == 4;
        const size_t steps_x = std::min<size_t>(16, width);
        const size_t steps_y = std::min<size_t>(16, height);
        unsigned lowest[3] { 255, 255, 255 }, highest[3] {}, sum[3] {};
        size_t count = 0;
        for (size_t sy = 0; sy < steps_y; ++sy) {
            const uint8_t* row = base + (sy * height / steps_y) * pitch;
            for (size_t sx = 0; sx < steps_x; ++sx) {
                const uint8_t* texel = row + (sx * width / steps_x) * bytes_per_pixel;
                for (size_t c = 0; c < (bgra ? 3u : 1u); ++c) {
                    lowest[c] = std::min<unsigned>(lowest[c], texel[c]);
                    highest[c] = std::max<unsigned>(highest[c], texel[c]);
                    sum[c] += texel[c];
                }
                ++count;
            }
        }
        out << " | plane " << plane;
        for (size_t c = 0; c < (bgra ? 3u : 1u); ++c) {
            out << (bgra ? (c == 0 ? " B " : c == 1 ? " G " : " R ") : " ") << "min " << lowest[c]
                << " max " << highest[c] << " avg " << (count != 0 ? sum[c] / count : 0u);
        }
    }
    CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
    return out.str();
}

} // namespace wallpaper::video
