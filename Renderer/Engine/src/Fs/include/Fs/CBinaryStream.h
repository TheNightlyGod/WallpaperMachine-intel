// Clean-room implementation from the WallpaperMachine spec e7-small-units.md; written without access to the original source.
#pragma once

#include <algorithm>
#include <cstdio>
#include <string>
#include <string_view>
#include <limits>
#include <cassert>
#include <memory>
#include <cerrno>
#include <cstring>
#include <sys/stat.h>
#include "IBinaryStream.h"
#include "Utils/Logging.h"

namespace wallpaper
{
namespace fs
{
template<typename TBinaryStream>
class CBinaryStream : public TBinaryStream {
public:
    // The handle belongs to this stream alone and is released here, once. Closing
    // flushes a writer; a failed flush is not reported.
    virtual ~CBinaryStream() {
        if (m_file != nullptr) std::fclose(m_file);
    }

protected:
    CBinaryStream(std::string_view path, std::FILE* file, bool writable)
        : m_path(path), m_file(file), m_writable(writable) {}
    virtual usize Write_impl(const void* buffer, usize sizeInBytes) override {
        // One item for a write that reached the file whole, none otherwise.
        if (sizeInBytes == 0) return 1;
        return std::fwrite(buffer, 1, sizeInBytes, m_file) == sizeInBytes ? 1 : 0;
    }

public:
    virtual usize Read(void* buffer, usize sizeInBytes) override {
        return std::fread(buffer, 1, sizeInBytes, m_file);
    }
    virtual char* Gets(char* buffer, usize sizeStr) override {
        if (buffer == nullptr || sizeStr == 0) return nullptr;
        constexpr usize kMostInt = static_cast<usize>(std::numeric_limits<int>::max());
        return std::fgets(buffer, static_cast<int>(std::min(sizeStr, kMostInt)), m_file);
    }
    virtual idx   Tell() const override {
        return static_cast<idx>(std::ftell(m_file));
    }
    // Like the other streams, only a position in [0, size] is reachable.
    virtual bool  SeekSet(idx offset) override { return SeekTo(offset); }
    virtual bool  SeekCur(idx offset) override {
        const idx cur = std::ftell(m_file);
        return cur >= 0 && SeekTo(cur + offset);
    }
    virtual bool  SeekEnd(idx offset) override { return SeekTo(Size() + offset); }
    virtual isize Size() const override {
        // A reader asks the file itself: that moves nothing and keeps the buffered
        // bytes, which the window streams' reposition-before-every-read relies on.
        if (! m_writable) {
            struct stat info {};
            return ::fstat(::fileno(m_file), &info) == 0 ? static_cast<isize>(info.st_size) : 0;
        }
        // A writer's pending bytes only count once flushed; seeking flushes them. The
        // position is put back, so it does not visibly move.
        const long here = std::ftell(m_file);
        if (here < 0 || std::fseek(m_file, 0, SEEK_END) != 0) return 0;
        const long end = std::ftell(m_file);
        std::fseek(m_file, here, SEEK_SET);
        return end < 0 ? 0 : static_cast<isize>(end);
    }

private:
    bool SeekTo(idx target) {
        if (target < 0 || target > Size()) return false;
        return std::fseek(m_file, target, SEEK_SET) == 0;
    }

    std::string m_path;
    std::FILE*  m_file;
    bool        m_writable;
};

template<typename TBinaryStream>
inline std::shared_ptr<TBinaryStream> t_CreateCBinaryStream(std::string_view path,
                                                            const char*      mode) {
    // Public constructor for make_shared; the base keeps its own protected.
    struct Opened final : CBinaryStream<TBinaryStream> {
        Opened(std::string_view p, std::FILE* f, bool writable)
            : CBinaryStream<TBinaryStream>(p, f, writable) {}
    };

    const auto refuse = [path](const char* why) -> std::shared_ptr<TBinaryStream> {
        LOG_ERROR("can't open \"%.*s\": %s", static_cast<int>(path.size()), path.data(), why);
        return nullptr;
    };
    // The path is used byte for byte, so one with a NUL in it names nothing.
    if (path.empty()) return refuse("the path is empty");
    if (path.find('\0') != std::string_view::npos) return refuse("the path contains a NUL byte");

    std::FILE* handle = std::fopen(std::string(path).c_str(), mode);
    if (handle == nullptr) return refuse(std::strerror(errno));
    // Reading a folder opens fine and fails later, so look at what was opened.
    struct stat info {};
    if (::fstat(::fileno(handle), &info) == 0 && S_ISDIR(info.st_mode)) {
        std::fclose(handle);
        return refuse("it is a folder, not a file");
    }
    // Only the reading mode leaves nothing pending in the handle.
    return std::make_shared<Opened>(path, handle, mode[0] != 'r' || std::strchr(mode, '+') != nullptr);
}

inline std::shared_ptr<IBinaryStream> CreateCBinaryStream(std::string_view path) {
    return t_CreateCBinaryStream<IBinaryStream>(path, "rb");
}
inline std::shared_ptr<IBinaryStreamW> CreateCBinaryStreamW(std::string_view path) {
    return t_CreateCBinaryStream<IBinaryStreamW>(path, "wb+");
}

} // namespace fs
} // namespace wallpaper
