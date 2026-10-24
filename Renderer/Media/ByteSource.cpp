#include "Media/ByteSource.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <utility>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace wallpaper::media
{

bool ReadExact(const ByteSource& source, std::uint64_t offset, void* destination, std::size_t length)
{
    return source.readAt(offset, destination, length) == length;
}

bool ReadVector(const ByteSource& source, std::uint64_t offset, std::uint64_t length,
                std::uint64_t limit, std::vector<std::uint8_t>* out, Error* error)
{
    if (length > limit) {
        return Fail(error, ErrorKind::LimitExceeded,
                    "a " + std::to_string(length) + " byte read exceeds the " +
                        std::to_string(limit) + " byte limit",
                    offset);
    }
    const std::uint64_t total = source.size();
    if (offset > total || length > total - offset) {
        return Fail(error, ErrorKind::Truncated, "the input ends before " + std::to_string(length) + " bytes", offset);
    }
    out->assign(static_cast<std::size_t>(length), 0);
    if (! ReadExact(source, offset, out->data(), out->size())) {
        out->clear();
        return source.ioFailed() ? Fail(error, ErrorKind::Io, "the read failed", offset)
                                 : Fail(error, ErrorKind::Truncated, "the input ends early", offset);
    }
    return true;
}

namespace
{

class MemoryByteSource final : public ByteSource {
public:
    MemoryByteSource(std::shared_ptr<const void> owner, const std::uint8_t* data, std::size_t size)
        : m_owner(std::move(owner)), m_data(size == 0 ? nullptr : data), m_size(size)
    {
    }

    std::uint64_t size() const override { return m_size; }

    std::size_t readAt(std::uint64_t offset, void* destination, std::size_t length) const override
    {
        if (offset >= m_size || length == 0) return 0;
        const std::size_t count = static_cast<std::size_t>(std::min<std::uint64_t>(length, m_size - offset));
        std::memcpy(destination, m_data + offset, count);
        return count;
    }

    const std::uint8_t* view(std::uint64_t offset, std::size_t length) const override
    {
        if (offset > m_size || length > m_size - offset) return nullptr;
        return m_data == nullptr ? nullptr : m_data + offset;
    }

private:
    std::shared_ptr<const void> m_owner;
    const std::uint8_t*         m_data;
    std::size_t                 m_size;
};

class FileByteSource final : public ByteSource {
public:
    FileByteSource(int descriptor, std::uint64_t size, std::size_t window)
        : m_descriptor(descriptor), m_size(size), m_windowCapacity(window)
    {
    }

    ~FileByteSource() override { ::close(m_descriptor); }

    std::uint64_t size() const override { return m_size; }

    std::size_t readAt(std::uint64_t offset, void* destination, std::size_t length) const override
    {
        if (offset >= m_size || length == 0) return 0;
        const std::size_t wanted = static_cast<std::size_t>(std::min<std::uint64_t>(length, m_size - offset));
        auto* out = static_cast<std::uint8_t*>(destination);
        std::size_t copied = 0;
        std::lock_guard<std::mutex> lock(m_mutex);
        while (copied < wanted) {
            const std::uint64_t position = offset + copied;
            const std::size_t   remaining = wanted - copied;
            if (remaining >= m_windowCapacity) {
                // A request this long gains nothing from the window.
                const std::size_t got = preadFully(out + copied, remaining, position);
                copied += got;
                if (got < remaining) break;
                continue;
            }
            if (! windowCovers(position) && ! fillWindow(position)) break;
            const std::uint64_t windowEnd = m_windowStart + m_window.size();
            const std::size_t   available = static_cast<std::size_t>(windowEnd - position);
            const std::size_t   count     = std::min(available, remaining);
            std::memcpy(out + copied, m_window.data() + (position - m_windowStart), count);
            copied += count;
        }
        return copied;
    }

    bool ioFailed() const override
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_ioFailed;
    }

private:
    bool windowCovers(std::uint64_t position) const
    {
        return position >= m_windowStart && position < m_windowStart + m_window.size();
    }

    // Loads the window that holds `position`, starting on a 4 KiB boundary.
    bool fillWindow(std::uint64_t position) const
    {
        constexpr std::uint64_t kPage = 4096;
        const std::uint64_t     start = position - position % kPage;
        const std::size_t       want  = static_cast<std::size_t>(
            std::min<std::uint64_t>(m_windowCapacity, m_size - start));
        m_window.resize(want);
        const std::size_t got = preadFully(m_window.data(), want, start);
        m_window.resize(got);
        m_windowStart = start;
        return windowCovers(position);
    }

    // pread until `length` bytes arrive, the file ends early, or an error occurs.
    std::size_t preadFully(std::uint8_t* destination, std::size_t length, std::uint64_t offset) const
    {
        std::size_t done = 0;
        while (done < length) {
            const std::uint64_t at = offset + done;
            if (at > static_cast<std::uint64_t>(INT64_MAX)) break;
            const ssize_t got = ::pread(m_descriptor, destination + done, length - done, static_cast<off_t>(at));
            if (got < 0) {
                if (errno == EINTR) continue;
                m_ioFailed = true;
                break;
            }
            if (got == 0) break;  // the file is shorter than it was when opened
            done += static_cast<std::size_t>(got);
        }
        return done;
    }

    int                           m_descriptor;
    std::uint64_t                 m_size;
    std::size_t                   m_windowCapacity;
    mutable std::mutex            m_mutex;
    mutable std::vector<std::uint8_t> m_window;
    mutable std::uint64_t         m_windowStart { 0 };
    mutable bool                  m_ioFailed { false };
};

} // namespace

std::shared_ptr<ByteSource> MakeMemoryByteSource(std::shared_ptr<const void> owner,
                                                 const std::uint8_t* data, std::size_t size)
{
    return std::make_shared<MemoryByteSource>(std::move(owner), data, size);
}

std::shared_ptr<ByteSource> MakeMemoryByteSource(std::vector<std::uint8_t> bytes)
{
    auto owned = std::make_shared<const std::vector<std::uint8_t>>(std::move(bytes));
    const std::uint8_t* data = owned->data();
    const std::size_t   size = owned->size();
    return std::make_shared<MemoryByteSource>(std::move(owned), data, size);
}

std::shared_ptr<ByteSource> OpenFileByteSource(const std::string& path, Error* error, std::size_t windowBytes)
{
    const int descriptor = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) {
        Fail(error, ErrorKind::Io, "cannot open the file: " + std::string(std::strerror(errno)));
        return nullptr;
    }
    struct stat info {};
    if (::fstat(descriptor, &info) != 0 || ! S_ISREG(info.st_mode) || info.st_size < 0) {
        ::close(descriptor);
        Fail(error, ErrorKind::Io, "not a regular file");
        return nullptr;
    }
    // A window under one page would make every read a system call.
    const std::size_t window = std::max<std::size_t>(windowBytes, 4096);
    return std::make_shared<FileByteSource>(descriptor, static_cast<std::uint64_t>(info.st_size), window);
}

std::shared_ptr<ByteSource> MakeSpilledByteSource(const std::uint8_t* data, std::size_t size, Error* error,
                                                  std::size_t windowBytes)
{
    const char*       base = std::getenv("TMPDIR");
    std::string       path = (base != nullptr && *base != '\0') ? base : "/tmp";
    if (path.back() != '/') path += '/';
    path += "wallpaper-machine-video-XXXXXX";
    const int descriptor = ::mkstemp(path.data());
    if (descriptor < 0) {
        Fail(error, ErrorKind::Io, "cannot create a temporary file: " + std::string(std::strerror(errno)));
        return nullptr;
    }
    // The name is only needed until the file exists; from here on the file is reachable by descriptor alone.
    ::unlink(path.c_str());
    ::fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    std::size_t written = 0;
    while (written < size) {
        const ssize_t put = ::write(descriptor, data + written, std::min<std::size_t>(size - written, 8U << 20));
        if (put < 0) {
            if (errno == EINTR) continue;
            Fail(error, ErrorKind::Io, "cannot write the temporary file: " + std::string(std::strerror(errno)));
            ::close(descriptor);
            return nullptr;
        }
        written += static_cast<std::size_t>(put);
    }
    const std::size_t window = std::max<std::size_t>(windowBytes, 4096);
    return std::make_shared<FileByteSource>(descriptor, static_cast<std::uint64_t>(size), window);
}

} // namespace wallpaper::media
