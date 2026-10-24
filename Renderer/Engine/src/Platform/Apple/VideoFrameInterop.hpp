#pragma once

#include "Video/VideoColorConversion.hpp"
#include "Video/VideoTextureSource.hpp"

#include <string>

namespace wallpaper::video
{

/// Turns a decoded Core Video pixel buffer into a frame. `retained_pixel_buffer`
/// is a CVPixelBufferRef the caller owns one reference to; that reference passes
/// to `out` (released by `ReleaseAppleVideoFrame`), and the IOSurface behind the
/// buffer, when it has one, is retained beside it. Fails, releasing the buffer,
/// when it is null.
bool AdoptPixelBufferAsVideoFrame(void* retained_pixel_buffer, VideoTextureFrame* out, std::string* error);

void ReleaseAppleVideoFrame(VideoTextureFrame* frame);
/// Copies `frame` into `out`, taking an independent reference on the platform
/// objects it points at. The copy stays valid after the producer releases its
/// own, which is what lets one decoder's frame be read by several surfaces;
/// the caller releases it with `ReleaseAppleVideoFrame`.
void RetainAppleVideoFrame(const VideoTextureFrame& frame, VideoTextureFrame* out);
std::string DescribeAppleVideoFrame(const VideoTextureFrame& frame);
/// Conversion constants for one decoded biplanar frame, read from the
/// colorimetry the decoder attached to it.
///
/// Exposed so a second GPU conversion path cannot choose a different range or
/// matrix from the one the lease's own NV12 import already uses. It decodes
/// nothing, allocates nothing and converts nothing; a frame that is not
/// biplanar YCbCr has no meaningful answer and gets the defaults.
[[nodiscard]] YuvColorParams AppleVideoFrameColorParams(const VideoTextureFrame& frame);
/// What a decoded biplanar frame says about its own colour: range, matrix,
/// bit depth, and for an HDR frame its transfer function, primaries and peak
/// (the content light level, else the mastering display's). A frame with no
/// pixel buffer gets the defaults. `AppleVideoFrameColorParams` is this, turned
/// into constants.
[[nodiscard]] YuvColorDescription AppleVideoFrameColorDescription(const VideoTextureFrame& frame);
/// Logs, once per distinct colorimetry, that a matrix had to be inferred from
/// the picture size because the stream declared none. Silent for a declared
/// matrix. Shared by every path that turns a frame's colorimetry into
/// conversion constants so the log reads the same whichever one ran.
void ReportInferredColor(const YuvColorDescription& description);

/// Logs, once per distinct colorimetry, how a 10-bit frame is being converted:
/// the curve and primaries it declared and, for HDR, the peak the tone map starts
/// from and whether that peak was stated or assumed.
void ReportTenBitColor(const YuvColorDescription& description);

} // namespace wallpaper::video
