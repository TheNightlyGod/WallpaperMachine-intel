// A bounds-checked cursor over bytes already in memory, for decoding the boxes
// and elements of untrusted files. A read past the end returns 0, moves nothing
// and latches `ok()` to false, so a parser can decode a whole structure and test
// once afterwards instead of checking every field.
#pragma once

#include <cstddef>
#include <cstdint>

namespace wallpaper::media
{

class ByteReader {
public:
    ByteReader() = default;
    ByteReader(const std::uint8_t* data, std::size_t size) : m_data(data), m_size(size) {}

    bool        ok() const { return m_ok; }
    std::size_t position() const { return m_position; }
    std::size_t size() const { return m_size; }
    std::size_t remaining() const { return m_size - m_position; }
    bool        atEnd() const { return m_position == m_size; }
    /// The bytes from the cursor on; valid for `remaining()` bytes.
    const std::uint8_t* cursor() const { return m_data + m_position; }

    std::uint8_t U8() { return static_cast<std::uint8_t>(readBig(1)); }
    std::uint16_t U16() { return static_cast<std::uint16_t>(readBig(2)); }
    std::uint32_t U24() { return static_cast<std::uint32_t>(readBig(3)); }
    std::uint32_t U32() { return static_cast<std::uint32_t>(readBig(4)); }
    std::uint64_t U64() { return readBig(8); }
    std::int8_t I8() { return static_cast<std::int8_t>(U8()); }
    std::int16_t I16() { return static_cast<std::int16_t>(U16()); }
    std::int32_t I32() { return static_cast<std::int32_t>(U32()); }
    std::int64_t I64() { return static_cast<std::int64_t>(U64()); }

    /// An unsigned big-endian integer of `width` bytes (0 to 8); 0 reads nothing.
    std::uint64_t Unsigned(std::size_t width)
    {
        if (width > 8) return fail();
        return readBig(width);
    }

    /// Moves the cursor forward; false (and latched failure) past the end.
    bool Skip(std::size_t count)
    {
        if (! m_ok || count > remaining()) return fail() != 0;
        m_position += count;
        return true;
    }

    /// Returns a pointer to the next `count` bytes and consumes them, or null
    /// (latching failure) when fewer remain.
    const std::uint8_t* Take(std::size_t count)
    {
        if (! m_ok || count > remaining()) {
            fail();
            return nullptr;
        }
        const std::uint8_t* start = m_data + m_position;
        m_position += count;
        return start;
    }

    /// A reader over the next `count` bytes, consumed here. On shortage this one
    /// fails and the returned reader is empty and failed too.
    ByteReader Sub(std::size_t count)
    {
        const std::uint8_t* start = Take(count);
        if (start == nullptr) {
            ByteReader failed;
            failed.m_ok = false;
            return failed;
        }
        return ByteReader(start, count);
    }

private:
    std::uint64_t fail()
    {
        m_ok = false;
        return 0;
    }

    std::uint64_t readBig(std::size_t width)
    {
        if (! m_ok || width > remaining()) return fail();
        std::uint64_t value = 0;
        for (std::size_t index = 0; index < width; ++index) {
            value = (value << 8) | m_data[m_position + index];
        }
        m_position += width;
        return value;
    }

    const std::uint8_t* m_data { nullptr };
    std::size_t         m_size { 0 };
    std::size_t         m_position { 0 };
    bool                m_ok { true };
};

} // namespace wallpaper::media
