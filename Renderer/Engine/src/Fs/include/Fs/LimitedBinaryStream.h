#pragma once
#include <algorithm>
#include <cstring>
#include <memory>
#include <vector>
#include "IBinaryStream.h"

#include "Core/Literals.hpp"

namespace wallpaper
{
namespace fs
{

// A read stream over `size` bytes of another stream starting at `start`; positions,
// sizes and seeks are all relative to that window.
class LimitedBinaryStream : public IBinaryStream {
public:
    LimitedBinaryStream(std::shared_ptr<IBinaryStream> infs, idx start, isize size)
        : m_pos(0), m_start(start), m_end(start + size), m_infs(infs) {}
    virtual ~LimitedBinaryStream() = default;

protected:
    virtual usize Write_impl(const void*, usize) { return 0; }

public:
    // Each read first puts the source at this window's position, so another reader
    // (or another window) moving the source in between does no harm.
    virtual usize Read(void* buffer, usize size) {
        const usize n = std::min(size, remaining());
        if (n == 0 || ! placeSource()) return 0;
        const usize got = m_infs->Read(buffer, n);
        m_pos += static_cast<idx>(got);
        return got;
    }
    // Like fgets, but never past the window's end.
    virtual char* Gets(char* buffer, usize size) {
        const usize room = std::min(size, remaining() + 1);
        if (room == 0 || remaining() == 0 || ! placeSource()) return nullptr;
        char* line = m_infs->Gets(buffer, room);
        if (line != nullptr) m_pos += static_cast<idx>(std::strlen(line));
        return line;
    }
    virtual idx  Tell() const { return m_pos; }
    virtual bool SeekSet(idx offset) { return seekTo(offset); }
    virtual bool SeekCur(idx offset) { return seekTo(m_pos + offset); }
    virtual bool SeekEnd(idx offset) { return seekTo(Size() + offset); }
    virtual isize Size() const { return m_end - m_start; }

private:
    usize remaining() const noexcept { return static_cast<usize>(Size() - m_pos); }

    // A position in [0, window size] is reachable; anything else leaves the stream alone.
    bool seekTo(idx target) noexcept {
        if (target < 0 || target > Size()) return false;
        m_pos = target;
        return true;
    }

    bool placeSource() { return m_infs && m_infs->SeekSet(m_start + m_pos); }

private:
    idx                            m_pos; // 0 <= m_pos <= m_end - m_start
    const idx                      m_start;
    const idx                      m_end; // end if m_pos == m_end - m_start
    std::shared_ptr<IBinaryStream> m_infs;
};

} // namespace fs
} // namespace wallpaper
