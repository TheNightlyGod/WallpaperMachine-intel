#include "Surface/PreviewPath.hpp"

#include <array>
#include <system_error>

namespace wallpaper::surface
{
namespace
{

namespace fs = std::filesystem;

constexpr std::array<const char*, 4> kConventionalNames { "preview.jpg",
                                                          "preview.jpeg",
                                                          "preview.png",
                                                          "preview.gif" };

/// `directory / relative` when that is a regular file of a usable size whose real
/// location is inside the real directory. Never throws.
std::optional<fs::path> UsableFileInside(const fs::path& directory, const std::string& relative)
{
    if (relative.empty()) return std::nullopt;
    const fs::path name(relative);
    if (name.is_absolute() || name.has_root_name() || name.has_root_directory()) return std::nullopt;
    for (const auto& part : name) {
        if (part == "..") return std::nullopt;
    }

    std::error_code error;
    const fs::path  root = fs::weakly_canonical(directory, error);
    if (error) return std::nullopt;
    const fs::path file = fs::weakly_canonical(root / name, error);
    if (error) return std::nullopt;

    // A prefix test on whole components, so `/lib/project-evil` is not inside
    // `/lib/project`.
    auto root_it = root.begin();
    auto file_it = file.begin();
    for (; root_it != root.end(); ++root_it, ++file_it) {
        if (file_it == file.end() || *file_it != *root_it) return std::nullopt;
    }
    if (file_it == file.end()) return std::nullopt;

    if (! fs::is_regular_file(file, error) || error) return std::nullopt;
    const auto size = fs::file_size(file, error);
    if (error || size == 0 || size > kMaxPreviewBytes) return std::nullopt;
    return file;
}

} // namespace

std::optional<std::filesystem::path>
PickPreviewFile(const std::filesystem::path& directory, const std::string& declared)
{
    if (auto file = UsableFileInside(directory, declared)) return file;
    for (const char* name : kConventionalNames) {
        if (auto file = UsableFileInside(directory, name)) return file;
    }
    return std::nullopt;
}

} // namespace wallpaper::surface
