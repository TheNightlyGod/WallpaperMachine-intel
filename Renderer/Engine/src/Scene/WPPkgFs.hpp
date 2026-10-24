#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "Fs/Fs.h"

namespace wallpaper
{
namespace fs
{
class WPPkgFs : public Fs {
public:
    virtual ~WPPkgFs() = default;
    static std::unique_ptr<WPPkgFs> CreatePkgFs(std::string_view pkgpath);

private:
    WPPkgFs() = default;

    // One published file of the package: where its bytes lie in the package file.
    struct Entry {
        std::int64_t begin { 0 }; // absolute offset in the package file
        std::int64_t size { 0 };
    };

    // The table index of the entry a path names (exact bytes first, then ASCII case
    // folded), or -1.
    long Find(std::string_view path) const;

private:
    std::string                                 m_path;
    std::vector<Entry>                          m_entries;
    std::unordered_map<std::string, std::size_t> m_exact;  // stored name -> first entry
    std::unordered_map<std::string, std::size_t> m_folded; // folded name -> first entry

public:
    bool                            Contains(std::string_view path) const override;
    std::shared_ptr<IBinaryStream>  Open(std::string_view path) override;
    std::shared_ptr<IBinaryStreamW> OpenW(std::string_view path) override;
};
} // namespace fs
} // namespace wallpaper
