// EBML (RFC 8794) primitives the Matroska reader is built from: variable-length
// element IDs and sizes, unsigned/signed/float/string payloads, and a walk over
// the children of a master element held in memory. Written from the RFC.
#pragma once

#include "Media/ByteReader.hpp"
#include "Media/Error.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace wallpaper::media::ebml
{

/// A size field whose value bits are all ones: "unknown", allowed on Segment and Cluster.
inline constexpr std::uint64_t kUnknownSize = ~std::uint64_t { 0 };

/// Number of bytes in the variable-length integer that starts with `first`
/// (1 to 8), or 0 when `first` is 0 (a length over 8 bytes, invalid).
inline int VintLength(std::uint8_t first)
{
    if (first == 0) return 0;
    int length = 1;
    for (std::uint8_t mask = 0x80; (first & mask) == 0; mask = static_cast<std::uint8_t>(mask >> 1)) ++length;
    return length;
}

/// An element ID: 1 to 4 bytes, returned with its length marker bit kept (the way
/// IDs are written in the specification, 0x1A45DFA3). False for an invalid or
/// over-long ID.
inline bool ReadId(ByteReader& reader, std::uint32_t* id)
{
    const std::uint8_t first = reader.U8();
    if (! reader.ok()) return false;
    const int length = VintLength(first);
    if (length == 0 || length > 4) return false;
    std::uint32_t value = first;
    for (int index = 1; index < length; ++index) value = (value << 8) | reader.U8();
    if (! reader.ok()) return false;
    *id = value;
    return true;
}

/// A size (or any "vint" value): 1 to 8 bytes with the marker removed. `*unknown`
/// is set when every value bit is 1; `*length` receives the byte count.
inline bool ReadVint(ByteReader& reader, std::uint64_t* value, bool* unknown = nullptr, int* length = nullptr)
{
    const std::uint8_t first = reader.U8();
    if (! reader.ok()) return false;
    const int bytes = VintLength(first);
    if (bytes == 0) return false;
    std::uint64_t result  = first & (0xFFU >> bytes);
    std::uint64_t allOnes = 0xFFU >> bytes;
    for (int index = 1; index < bytes; ++index) {
        result  = (result << 8) | reader.U8();
        allOnes = (allOnes << 8) | 0xFF;
    }
    if (! reader.ok()) return false;
    if (unknown != nullptr) *unknown = result == allOnes;
    if (length != nullptr) *length = bytes;
    *value = result;
    return true;
}

/// A signed vint as used by EBML lacing: the unsigned value minus (2^(7n-1) - 1).
inline bool ReadSignedVint(ByteReader& reader, std::int64_t* value)
{
    std::uint64_t raw    = 0;
    int           length = 0;
    if (! ReadVint(reader, &raw, nullptr, &length)) return false;
    const std::int64_t bias = (std::int64_t { 1 } << (7 * length - 1)) - 1;
    *value = static_cast<std::int64_t>(raw) - bias;
    return true;
}

/// A big-endian unsigned integer of 0 to 8 bytes (0 bytes is 0).
inline bool ReadUnsigned(ByteReader payload, std::uint64_t* value)
{
    if (payload.size() > 8) return false;
    *value = payload.Unsigned(payload.size());
    return payload.ok();
}

inline bool ReadSigned(ByteReader payload, std::int64_t* value)
{
    if (payload.size() > 8) return false;
    const std::size_t width = payload.size();
    std::uint64_t raw = payload.Unsigned(width);
    if (! payload.ok()) return false;
    if (width > 0 && width < 8 && (raw & (std::uint64_t { 1 } << (8 * width - 1))) != 0) raw |= ~std::uint64_t { 0 } << (8 * width);
    *value = static_cast<std::int64_t>(raw);
    return true;
}

/// A 4- or 8-byte IEEE float; an empty payload is 0.
inline bool ReadFloat(ByteReader payload, double* value)
{
    if (payload.size() == 0) {
        *value = 0.0;
        return true;
    }
    if (payload.size() == 4) {
        const std::uint32_t bits = payload.U32();
        float               single = 0;
        std::memcpy(&single, &bits, sizeof(single));
        *value = static_cast<double>(single);
        return true;
    }
    if (payload.size() == 8) {
        const std::uint64_t bits = payload.U64();
        std::memcpy(value, &bits, sizeof(*value));
        return true;
    }
    return false;
}

/// ASCII/UTF-8 text up to the first NUL.
inline std::string ReadString(ByteReader payload)
{
    const char* data = reinterpret_cast<const char*>(payload.Take(payload.size()));
    if (data == nullptr) return {};
    std::size_t length = 0;
    while (length < payload.size() && data[length] != '\0') ++length;
    return std::string(data, length);
}

} // namespace wallpaper::media::ebml
