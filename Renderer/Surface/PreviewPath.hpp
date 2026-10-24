// Which file of a wallpaper project is its preview picture.
//
// Pure C++17: no Apple framework and no JSON library, so the rule that keeps a
// project from naming a file outside its own folder is tested on its own.
#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>

namespace wallpaper::surface
{

/// The largest preview file read. A preview is a thumbnail the author shipped;
/// a file beyond this is not one, and decoding it would cost more memory than a
/// failure screen is worth.
inline constexpr std::uintmax_t kMaxPreviewBytes = 32u * 1024u * 1024u;

/// The preview of the project in `directory`: the file `declared` names (the
/// `preview` key of `project.json`) when that is a regular file inside the
/// directory, otherwise the first of `preview.jpg`, `preview.jpeg`,
/// `preview.png` and `preview.gif` that is.
///
/// `declared` is untrusted. An absolute path, a `..` component and a symbolic
/// link that leaves the directory all fall through to the conventional names
/// instead of being followed, and a file over `kMaxPreviewBytes` is skipped.
/// Empty when the project has no usable preview.
[[nodiscard]] std::optional<std::filesystem::path>
PickPreviewFile(const std::filesystem::path& directory, const std::string& declared);

} // namespace wallpaper::surface
