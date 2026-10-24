#pragma once
// A plain video file as the image a video texture source opens it from.
//
// The scene engine no longer plays a plain video wallpaper -- the host does, with its own
// players -- so nothing in production builds an image that names a media file on disk. The
// decoders still open one (`Image::videoFilePath`), and the tests that drive them over media
// they encode for themselves build that image here, the way the engine once did for a video
// project: the file is resolved against the project directory, must stay inside it, and is only
// probed, never read.

#include "Image.hpp"
#include "Media/ByteSource.hpp"
#include "Video/VideoContainerProbe.hpp"

#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>
#include <string_view>
#include <utility>

namespace wallpaper::video
{

inline void SetProjectImageError(std::string* error, std::string message)
{
    if (error != nullptr) *error = std::move(message);
}

inline std::shared_ptr<Image> CreateVideoProjectImage(const std::filesystem::path& project_directory,
                                               std::string_view             file_name,
                                               std::string*                 error)
{
    if (file_name.empty()) {
        SetProjectImageError(error, "video project file entry must not be empty");
        return nullptr;
    }

    std::filesystem::path media_path(file_name);
    if (media_path.is_relative()) media_path = project_directory / media_path;

    // Both sides are canonicalised before they are compared, so a symlink is
    // followed first and a link that leaves the project is rejected rather
    // than read.
    std::error_code ec;
    const std::filesystem::path resolved_media = std::filesystem::canonical(media_path, ec);
    if (ec) {
        SetProjectImageError(error,
                 std::string("failed to open video project media file: ") + media_path.string());
        return nullptr;
    }
    const std::filesystem::path resolved_project = std::filesystem::canonical(project_directory, ec);
    if (ec) {
        SetProjectImageError(error,
                 std::string("failed to open video project media file: ") + media_path.string());
        return nullptr;
    }

    const std::filesystem::path relative = resolved_media.lexically_relative(resolved_project);
    if (relative.empty() || relative.begin()->native() == "..") {
        SetProjectImageError(error,
                 std::string("video project media file escapes the project directory: ") +
                     resolved_media.string());
        return nullptr;
    }

    if (!std::filesystem::is_regular_file(resolved_media, ec) || ec) {
        SetProjectImageError(error,
                 std::string("failed to open video project media file: ") + media_path.string());
        return nullptr;
    }
    if (std::filesystem::file_size(resolved_media, ec) == 0 || ec) {
        SetProjectImageError(error,
                 std::string("video project media file is empty: ") + media_path.string());
        return nullptr;
    }

    // The project's own readers give the picture size from the file's headers; the
    // file is read through a small window, never whole.
    media::Error media_error;
    const auto   source = media::OpenFileByteSource(resolved_media.string(), &media_error);
    if (source == nullptr) {
        SetProjectImageError(error, "failed to open video file: " + media::Describe(media_error));
        return nullptr;
    }
    std::string why_not;
    const auto  metadata = ProbeVideoMetadataFromSource(source, &why_not);
    if (!metadata) {
        SetProjectImageError(error, "failed to probe video file: " + why_not);
        return nullptr;
    }
    const uint32_t source_width  = metadata->width;
    const uint32_t source_height = metadata->height;

    auto image = std::make_shared<Image>();
    image->key = std::string(file_name);
    // The wallpaper's own file is the decode input. Nothing reads it into this
    // process and nothing writes a second copy of it, which is why the image
    // carries no slots.
    image->videoFilePath            = resolved_media.string();
    // Single frame, clamped and linear: how a decoded video frame is sampled.
    ImageHeader& header = image->header;
    header.isVideo = true;
    header.videoAudioEnabled = true;
    header.count = 1;
    header.sample.wrapS = header.sample.wrapT = TextureWrap::CLAMP_TO_EDGE;
    header.sample.minFilter = header.sample.magFilter = TextureFilter::LINEAR;
    header.width = header.mapWidth = static_cast<i32>(source_width);
    header.height = header.mapHeight = static_cast<i32>(source_height);
    return image;
}

} // namespace wallpaper::video
