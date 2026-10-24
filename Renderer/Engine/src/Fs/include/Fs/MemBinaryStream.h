#pragma once

#include <algorithm>
#include <cstring>
#include <iterator>
#include <memory>
#include <vector>

#include "IBinaryStream.h"
#include "Utils/Logging.h"

namespace wallpaper
{
namespace fs
{

// A read stream over bytes it owns, either handed over or copied out of another
// stream (from that stream's current position to its end).
class MemBinaryStream : public IBinaryStream {
public:
    MemBinaryStream(std::vector<uint8_t>&& data): m_pos(0), m_data(std::move(data)) {}
    MemBinaryStream(IBinaryStream& source): m_pos(0) {
        const isize left = source.Size() - source.Tell();
        if (left <= 0) return;
        m_data.resize(static_cast<usize>(left));
        m_data.resize(source.Read(m_data.data(), m_data.size()));
    }

    virtual ~MemBinaryStream() = default;

public:
    virtual usize Read(void* buffer, usize size) {
        const usize n = std::min(size, remaining());
        if (n > 0) std::memcpy(buffer, m_data.data() + m_pos, n);
        m_pos += static_cast<idx>(n);
        return n;
    }
    // Like fgets: at most size - 1 bytes, up to and including a newline, always
    // terminated; null when nothing could be read.
    virtual char* Gets(char* buffer, usize size) {
        if (size == 0 || remaining() == 0) return nullptr;
        usize n = 0;
        while (n + 1 < size && remaining() > 0) {
            const char c = static_cast<char>(m_data[static_cast<usize>(m_pos++)]);
            buffer[n++]  = c;
            if (c == '\n') break;
        }
        buffer[n] = '\0';
        return buffer;
    }
    virtual idx  Tell() const { return m_pos; }
    virtual bool SeekSet(idx offset) { return seekTo(offset); }
    virtual bool SeekCur(idx offset) { return seekTo(m_pos + offset); }
    virtual bool SeekEnd(idx offset) { return seekTo(Size() + offset); }
    virtual isize Size() const { return std::ssize(m_data); }

protected:
    virtual usize Write_impl(const void*, usize) { return 0; }

private:
    usize remaining() const noexcept { return static_cast<usize>(Size() - m_pos); }

    // A position in [0, size] is reachable; anything else leaves the stream alone.
    bool seekTo(idx target) noexcept {
        if (target < 0 || target > Size()) return false;
        m_pos = target;
        return true;
    }

    idx                  m_pos;
    std::vector<uint8_t> m_data;
};

} // namespace fs
} // namespace wallpaper
