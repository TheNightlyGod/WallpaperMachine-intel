#pragma once
#include <bit>
#include <cstdint>
#include <string>
#include <type_traits>
#include "Core/NoCopyMove.hpp"
#include "Core/Literals.hpp"

namespace wallpaper
{
namespace fs
{

class IBinaryStream : NoCopy, NoMove {
    // Integers in the files this engine reads are little-endian and are read
    // straight into the value, so the host has to be little-endian too.
    static_assert(std::endian::native == std::endian::little,
                  "binary streams read little-endian values by copying them");

protected:
    // A value of the type's width from the current position, or 0 when fewer bytes
    // than that are left.
    template<typename T>
    T _ReadInt() {
        T value { 0 };
        if (Read(&value, sizeof(T)) != sizeof(T)) return T { 0 };
        return value;
    }

public:
    IBinaryStream()          = default;
    virtual ~IBinaryStream() = default;

    float ReadFloat() {
        float value { 0.0f };
        if (Read(&value, sizeof(value)) != sizeof(value)) return 0.0f;
        return value;
    }

    // Fixed-width little-endian integers; 0 when the stream holds fewer bytes than the width.
    i64 ReadInt64() {
        return _ReadInt<i64>();
    }
    u64 ReadUint64() {
        return _ReadInt<u64>();
    }
    i32 ReadInt32() {
        return _ReadInt<i32>();
    }
    u32 ReadUint32() {
        return _ReadInt<u32>();
    }
    i16 ReadInt16() {
        return _ReadInt<i16>();
    }
    u16 ReadUint16() {
        return _ReadInt<u16>();
    }
    i8 ReadInt8() {
        return _ReadInt<i8>();
    }
    u8 ReadUint8() {
        return _ReadInt<u8>();
    }

    // Bytes up to the next NUL, which is consumed but not returned; or whatever was
    // left when the stream ended first.
    std::string ReadStr() {
        std::string text;
        char        c { 0 };
        while (Read(&c, 1) == 1 && c != '\0') text.push_back(c);
        return text;
    }

    // Every byte from the current position to the end.
    std::string ReadAllStr() {
        const isize left = Size() - Tell();
        if (left <= 0) return {};
        std::string text(static_cast<usize>(left), '\0');
        text.resize(Read(text.data(), text.size()));
        return text;
    }

    // Back to the first byte.
    bool Rewind() {
        return SeekSet(0);
    }

    usize Usize() const noexcept {
        return static_cast<usize>(Size());
    }

    // The primitives a concrete stream supplies.
    // `Read` returns how many bytes it delivered; `Gets` behaves like fgets.
    virtual usize Read(void* buffer, usize sizeInByte)  = 0;
    virtual char* Gets(char* buffer, usize sizeStr)     = 0;
    virtual idx   Tell() const                          = 0;
    // Positioning: from the start, from here, from the end.
    virtual bool SeekSet(idx offset) = 0;
    virtual bool SeekCur(idx offset) = 0;
    virtual bool SeekEnd(idx offset) = 0;
    virtual isize Size() const       = 0;

protected:
    // Only the writing wrapper below reaches this.
    virtual usize Write_impl(const void* buffer, usize sizeInByte) = 0;
};

// A stream that can also be written. It inherits privately, so a caller of the
// writer never gets at the read side through it.
class IBinaryStreamW : IBinaryStream {
public:
    virtual ~IBinaryStreamW() = default;

    usize Write(const void* buffer, usize sizeInByte) {
        return Write_impl(buffer, sizeInByte);
    }
};

} // namespace fs
} // namespace wallpaper
