// Byte-level fixtures for the format tests: a little-endian writer and an
// in-memory file space, so a test can hand the parsers exactly the bytes it
// wants without touching the disk.
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "Fs/Fs.h"
#include "Fs/MemBinaryStream.h"

namespace wallpaper::test
{

class Bytes {
public:
    Bytes& u8(uint32_t v) {
        m_data.push_back(static_cast<uint8_t>(v));
        return *this;
    }
    Bytes& u16(uint32_t v) {
        u8(v & 0xFF);
        return u8((v >> 8) & 0xFF);
    }
    Bytes& u32(uint32_t v) {
        u16(v & 0xFFFF);
        return u16((v >> 16) & 0xFFFF);
    }
    Bytes& i32(int32_t v) { return u32(static_cast<uint32_t>(v)); }
    Bytes& f32(float v) {
        uint32_t bits;
        std::memcpy(&bits, &v, sizeof bits);
        return u32(bits);
    }
    Bytes& raw(const std::vector<uint8_t>& v) {
        m_data.insert(m_data.end(), v.begin(), v.end());
        return *this;
    }
    Bytes& raw(std::initializer_list<uint8_t> v) {
        m_data.insert(m_data.end(), v.begin(), v.end());
        return *this;
    }
    Bytes& raw(const void* p, size_t n) {
        auto* b = static_cast<const uint8_t*>(p);
        m_data.insert(m_data.end(), b, b + n);
        return *this;
    }
    Bytes& fill(size_t n, uint8_t value) {
        m_data.insert(m_data.end(), n, value);
        return *this;
    }
    // The text followed by one NUL.
    Bytes& cstr(std::string_view s) {
        m_data.insert(m_data.end(), s.begin(), s.end());
        return u8(0);
    }
    // Four letters, four decimal digits, a NUL: nine bytes.
    Bytes& stamp(std::string_view name, int version) {
        char digits[8];
        std::snprintf(digits, sizeof digits, "%04d", version);
        m_data.insert(m_data.end(), name.begin(), name.end());
        for (int i = 0; i < 4; ++i) m_data.push_back(static_cast<uint8_t>(digits[i]));
        return u8(0);
    }
    // A column-major 4x4 identity whose fourth column is (x, y, z).
    Bytes& matrix(float x, float y, float z) {
        for (int c = 0; c < 4; ++c) {
            for (int r = 0; r < 4; ++r) {
                if (c == 3 && r < 3) f32(r == 0 ? x : r == 1 ? y : z);
                else f32(r == c ? 1.0f : 0.0f);
            }
        }
        return *this;
    }
    // The same matrix with a caller-chosen first float, for non-finite checks.
    Bytes& matrixWithFirst(float first, float x, float y, float z) {
        const size_t at = m_data.size();
        matrix(x, y, z);
        std::memcpy(m_data.data() + at, &first, sizeof first);
        return *this;
    }
    void patchU32(size_t at, uint32_t v) {
        for (int i = 0; i < 4; ++i) m_data[at + i] = static_cast<uint8_t>((v >> (8 * i)) & 0xFF);
    }
    size_t size() const { return m_data.size(); }
    const std::vector<uint8_t>& data() const { return m_data; }
    std::vector<uint8_t>& data() { return m_data; }
    // The same bytes with `n` taken off the end.
    std::vector<uint8_t> without(size_t n) const {
        return std::vector<uint8_t>(m_data.begin(), m_data.end() - static_cast<std::ptrdiff_t>(n));
    }

private:
    std::vector<uint8_t> m_data;
};

// Serves files from a map keyed by the path inside the mount point.
class MapFs final : public fs::Fs {
public:
    using Files = std::map<std::string, std::vector<uint8_t>>;
    explicit MapFs(Files files): m_files(std::move(files)) {}

    bool Contains(std::string_view path) const override {
        return m_files.find(std::string(path)) != m_files.end();
    }
    std::shared_ptr<fs::IBinaryStream> Open(std::string_view path) override {
        auto it = m_files.find(std::string(path));
        if (it == m_files.end()) return nullptr;
        return std::make_shared<fs::MemBinaryStream>(std::vector<uint8_t>(it->second));
    }
    std::shared_ptr<fs::IBinaryStreamW> OpenW(std::string_view) override { return nullptr; }

private:
    Files m_files;
};

} // namespace wallpaper::test
