#include "Video/VideoContainerProbe.hpp"

#include "Media/ByteSource.hpp"
#include "Media/DisplayMatrix.hpp"
#include "Media/IsoBmff/IsoBmffReader.hpp"
#include "Media/Matroska/MatroskaReader.hpp"
#include "Media/VideoTypes.hpp"
#include "Video/VideoDisplayTransform.hpp"

#include <cmath>
#include <memory>

namespace wallpaper::video
{

bool DisplaySizeOf(const media::VideoStreamInfo& info, uint32_t* width, uint32_t* height)
{
    if (width == nullptr || height == nullptr) return false;
    uint32_t resolved_width  = info.codedWidth;
    uint32_t resolved_height = info.codedHeight;
    if (resolved_width == 0 || resolved_height == 0) return false;
    if (info.displayMatrix != media::kIdentityDisplayMatrix) {
        const auto transform = ResolveVideoDisplayTransform(info.displayMatrix, resolved_width, resolved_height);
        if (! transform) return false;
        resolved_width  = transform->width;
        resolved_height = transform->height;
    }
    *width  = resolved_width;
    *height = resolved_height;
    return true;
}

std::optional<VideoMetadata> ProbeVideoMetadataFromMemory(std::span<const char> payload,
                                                          std::string*          why_not)
{
    if (payload.empty()) {
        if (why_not != nullptr) *why_not = "empty payload";
        return std::nullopt;
    }
    // The payload outlives this call and nothing keeps the source, so it owns nothing.
    const auto source = media::MakeMemoryByteSource(
        std::shared_ptr<const void>(), reinterpret_cast<const std::uint8_t*>(payload.data()), payload.size());
    return ProbeVideoMetadataFromSource(source, why_not);
}

std::optional<VideoMetadata> ProbeVideoMetadataFromSource(const std::shared_ptr<media::ByteSource>& source,
                                                          std::string*                              why_not)
{
    const auto decline = [&](std::string reason) -> std::optional<VideoMetadata> {
        if (why_not != nullptr) *why_not = std::move(reason);
        return std::nullopt;
    };
    if (source == nullptr) return decline("no source");

    media::VideoStreamInfo info;
    media::Error           error;
    if (media::LooksLikeIsoBmff(*source)) {
        const auto reader = media::IsoBmffReader::Open(source, &error);
        if (reader == nullptr) return decline(media::Describe(error));
        info = reader->info();
    } else if (std::uint8_t header[4] {};
               media::ReadExact(*source, 0, header, sizeof(header)) && header[0] == 0x1A && header[1] == 0x45 &&
               header[2] == 0xDF && header[3] == 0xA3) {
        // WebM and Matroska: the headers alone give the size and the length the file
        // states. Only a file that states no length is
        // indexed whole to find where its last frame ends.
        media::MatroskaOptions options;
        options.buildIndex = false;
        auto reader        = media::MatroskaReader::Open(source, &error, options);
        if (reader == nullptr) return decline(media::Describe(error));
        if (reader->videoInfo().durationTicks <= 0) {
            options.buildIndex = true;
            reader             = media::MatroskaReader::Open(source, &error, options);
            if (reader == nullptr) return decline(media::Describe(error));
        }
        info = reader->videoInfo();
    } else {
        return decline("neither an ISO base media file nor Matroska");
    }

    VideoMetadata metadata;
    if (! DisplaySizeOf(info, &metadata.width, &metadata.height)) {
        return decline("video display transform is not a valid affine transform");
    }
    if (info.timescale > 0 && info.durationTicks > 0) {
        const double seconds = static_cast<double>(info.durationTicks) / static_cast<double>(info.timescale);
        if (std::isfinite(seconds)) metadata.duration_seconds = seconds;
    }
    return metadata;
}

} // namespace wallpaper::video
