// Where a container reader gets its bytes: a size and positioned reads, with an
// optional zero-copy view when the bytes are already in memory. The readers take
// a ByteSource and never touch a path, so the same parser serves a file, a video
// payload embedded in a `.tex` package, and a test's byte array.
//
// Reads never throw and never read past the end: a request that crosses the end
// of the input is shortened, and one that starts at or after it returns 0. An
// implementation is safe to call from several threads.
#pragma once

#include "Media/Error.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace wallpaper::media
{

class ByteSource {
public:
    virtual ~ByteSource() = default;

    /// Total bytes, fixed when the source was created.
    virtual std::uint64_t size() const = 0;

    /// Copies up to `length` bytes starting at `offset` into `destination` and
    /// returns how many were copied: fewer than `length` only at the end of the
    /// input (or after `ioFailed()`), 0 when `offset >= size()`.
    virtual std::size_t readAt(std::uint64_t offset, void* destination, std::size_t length) const = 0;

    /// A pointer to `length` bytes at `offset` that stays valid as long as this
    /// source does, or null when the source cannot lend them (the range is
    /// outside the input, or the bytes are not in memory). Never required: a
    /// caller falls back to readAt.
    virtual const std::uint8_t* view(std::uint64_t offset, std::size_t length) const
    {
        (void) offset;
        (void) length;
        return nullptr;
    }

    /// True once an underlying read failed for a reason other than reaching the
    /// end of the input (for a file: a disk or permission error). Latched.
    virtual bool ioFailed() const { return false; }
};

/// True when exactly `length` bytes at `offset` were read into `destination`.
bool ReadExact(const ByteSource& source, std::uint64_t offset, void* destination, std::size_t length);

/// Reads exactly `length` bytes at `offset` into `*out` (resized to fit). Fails
/// with `Truncated` when the input is shorter, `Io` when the source failed, and
/// `LimitExceeded` when `length` is more than `limit`, before allocating.
bool ReadVector(const ByteSource& source, std::uint64_t offset, std::uint64_t length,
                std::uint64_t limit, std::vector<std::uint8_t>* out, Error* error);

/// A source over bytes in memory. The bytes are shared, not copied: `owner`
/// keeps whatever owns them alive for as long as the source lives, so a caller
/// can hand over a buffer it also keeps using, or one it is about to drop.
std::shared_ptr<ByteSource> MakeMemoryByteSource(std::shared_ptr<const void> owner,
                                                 const std::uint8_t* data, std::size_t size);

/// A memory source that takes ownership of `bytes`.
std::shared_ptr<ByteSource> MakeMemoryByteSource(std::vector<std::uint8_t> bytes);

/// A source over a copy of `data` kept in an anonymous file: created in the
/// temporary directory, unlinked before the first byte is written, and read back
/// with `pread` through the same small window as a file. Nothing is visible on
/// disk, nothing is left behind when the process dies, and the copy costs the
/// process no memory (the pages are the system's file cache, which it can take
/// back), so a large payload that is only read a frame at a time does not stay
/// resident. Returns null and fills `error` (kind `Io`) when the file cannot be
/// created or written whole.
std::shared_ptr<ByteSource> MakeSpilledByteSource(const std::uint8_t* data, std::size_t size, Error* error,
                                                  std::size_t windowBytes = 64 * 1024);

/// A read-only file read through a small buffered window (64 KiB by default), so
/// a parser's many short header reads cost one system call each window instead
/// of one each. Reads at least a window long bypass the buffer. The file is
/// never mapped: a file truncated while open shortens the read instead of
/// faulting. Returns null and fills `error` (kind `Io`) when the path cannot be
/// opened or is not a regular file.
std::shared_ptr<ByteSource> OpenFileByteSource(const std::string& path, Error* error,
                                               std::size_t windowBytes = 64 * 1024);

} // namespace wallpaper::media
