#pragma once

#include <filesystem>
#include "Fs.h"
#include "CBinaryStream.h"
#include "Utils/Logging.h"

namespace wallpaper
{
namespace fs
{

class PhysicalFs : public Fs {
public:
    PhysicalFs(std::string_view physicalPath): m_path(physicalPath) {}
    virtual ~PhysicalFs() = default;
    // Only regular files count; a directory is never "found".
    bool Contains(std::string_view path) const override {
        std::filesystem::path full;
        if (! Resolve(path, &full)) return false;
        std::error_code failure;
        return std::filesystem::is_regular_file(full, failure) && ! failure;
    }
    std::shared_ptr<IBinaryStream> Open(std::string_view path) override {
        std::filesystem::path full;
        if (! Resolve(path, &full)) return nullptr;
        return CreateCBinaryStream(full.string());
    }
    std::shared_ptr<IBinaryStreamW> OpenW(std::string_view path) override {
        std::filesystem::path full;
        if (! Resolve(path, &full)) return nullptr;
        std::error_code failure;
        std::filesystem::create_directories(full.parent_path(), failure);
        if (failure) {
            LOG_ERROR("can't create the folder of \"%s\": %s",
                      full.string().c_str(),
                      failure.message().c_str());
            return nullptr;
        }
        return CreateCBinaryStreamW(full.string());
    }
    bool PhysicalPath(std::string_view path, std::string* out) const override {
        std::filesystem::path full;
        if (out == nullptr || ! Contains(path) || ! Resolve(path, &full)) return false;
        *out = full.string();
        return true;
    }
    bool Rename(std::string_view from, std::string_view to) override {
        std::filesystem::path from_full, to_full;
        if (! Resolve(from, &from_full) || ! Resolve(to, &to_full)) return false;
        std::error_code failure;
        std::filesystem::rename(from_full, to_full, failure);
        if (! failure) return true;
        // The source is this writer's own temporary file, so removing it leaves
        // nothing behind for a rename that could not be completed.
        std::error_code ignored;
        std::filesystem::remove(from_full, ignored);
        return false;
    }

private:
    // `path` is below the mount: it starts with '/' and every segment after it is a
    // plain name. A `..` or empty segment, an embedded NUL or a missing leading '/'
    // could name something outside the folder, so such a path names nothing.
    bool Resolve(std::string_view path, std::filesystem::path* out) const {
        if (path.size() < 2 || path.front() != '/') return false;
        if (path.find('\0') != std::string_view::npos) return false;
        std::string_view rest = path.substr(1);
        std::filesystem::path relative;
        for (;;) {
            const auto        slash   = rest.find('/');
            const std::string_view seg = rest.substr(0, slash);
            if (seg.empty() || seg == "..") return false;
            relative /= std::filesystem::path(std::string(seg));
            if (slash == std::string_view::npos) break;
            rest.remove_prefix(slash + 1);
        }
        *out = m_path / relative;
        return true;
    }
    std::filesystem::path m_path;
};

// A folder file space; a missing folder is created only when `create` is set.
// Null when the folder is absent (and not to be created), cannot be created, or is
// not a folder.
inline std::unique_ptr<PhysicalFs> CreatePhysicalFs(std::string_view path, bool create = false) {
    const std::string     text { path };
    const std::filesystem::path folder { text };
    std::error_code       failure;
    if (! std::filesystem::exists(folder, failure)) {
        if (! create) {
            LOG_ERROR("\"%s\" not exists", text.c_str());
            return nullptr;
        }
        std::filesystem::create_directories(folder, failure);
        if (failure || ! std::filesystem::is_directory(folder, failure)) {
            LOG_ERROR("mkdir \"%s\" failed", text.c_str());
            return nullptr;
        }
    } else if (! std::filesystem::is_directory(folder, failure)) {
        LOG_ERROR("\"%s\" is not a folder", text.c_str());
        return nullptr;
    }
    return std::make_unique<PhysicalFs>(path);
}
} // namespace fs
} // namespace wallpaper
