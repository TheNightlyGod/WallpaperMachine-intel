// Clean-room implementation from the WallpaperMachine spec e1b-scene-model.md; written without access to the original source.
#include "SceneIndexArray.h"
#include <atomic>
#include <cstring>
#include <utility>

using namespace wallpaper;

namespace
{
uint32_t* AllocateSlots(usize slots) {
    if (slots == 0) return nullptr;
    auto* data = new uint32_t[slots];
    std::memset(data, 0, slots * sizeof(uint32_t));
    return data;
}

bool QuadSlots(usize quadCount, SceneIndexWidth width, usize& slots) {
    const uint64_t per_quad = width == SceneIndexWidth::UInt32 ? 6ull : 3ull;
    uint64_t       count    = 0;
    if (! CheckedMulU64(quadCount, per_quad, count) ||
        count > std::numeric_limits<usize>::max() ||
        count > std::numeric_limits<usize>::max() / sizeof(uint32_t)) {
        return false;
    }
    slots = static_cast<usize>(count);
    return true;
}
} // namespace

uint64_t SceneIndexArray::NewRevision() noexcept {
    static std::atomic<uint64_t> next { 1 };
    return next.fetch_add(1, std::memory_order_relaxed);
}

SceneIndexArray::SceneIndexArray(std::size_t indexCount)
    : SceneIndexArray(indexCount, SceneIndexWidth::UInt16) {}

SceneIndexArray::SceneIndexArray(std::size_t quadCount, SceneIndexWidth width)
    : m_pData(nullptr), m_size(0), m_capacity(0), m_width(width) {
    usize slots = 0;
    if (! QuadSlots(quadCount, width, slots)) return;
    m_capacity = slots;
    m_pData    = AllocateSlots(slots);
}

SceneIndexArray::SceneIndexArray(std::span<const uint32_t> data) {
    if (data.empty()) return;
    m_pData = new uint32_t[data.size()];
    std::memcpy(m_pData, data.data(), data.size() * sizeof(uint32_t));
    m_size          = data.size();
    m_capacity      = data.size();
    m_written_bytes = data.size_bytes();
}

SceneIndexArray::SceneIndexArray(std::span<const uint16_t> data)
    : m_width(SceneIndexWidth::UInt16) {
    const usize slots = data.size() / 2 + data.size() % 2;
    if (slots > std::numeric_limits<usize>::max() / sizeof(uint32_t)) return;
    m_pData = AllocateSlots(slots);
    if (!data.empty()) std::memcpy(m_pData, data.data(), data.size_bytes());
    m_size = m_capacity = slots;
    m_written_bytes = data.size_bytes();
    m_explicit_draw_count = data.size();
}

SceneIndexArray SceneIndexArray::FromUInt32(std::span<const uint32_t> data) {
    SceneIndexArray out(data);
    out.m_width = SceneIndexWidth::UInt32;
    out.m_explicit_draw_count = data.size();
    return out;
}

SceneIndexArray::SceneIndexArray(SceneIndexArray&& o) noexcept
    : m_pData(std::exchange(o.m_pData, nullptr)),
      m_size(std::exchange(o.m_size, 0)),
      m_capacity(std::exchange(o.m_capacity, 0)),
      m_written_bytes(std::exchange(o.m_written_bytes, 0)),
      // The bytes move with the revision that names them; what stays behind is empty.
      m_revision(std::exchange(o.m_revision, NewRevision())),
      m_render_size(std::exchange(o.m_render_size, std::numeric_limits<usize>::max())),
      m_explicit_draw_count(std::exchange(o.m_explicit_draw_count, std::numeric_limits<usize>::max())),
      m_width(o.m_width),
      m_id(std::exchange(o.m_id, 0)) {}

SceneIndexArray::~SceneIndexArray() { delete[] m_pData; }

SceneIndexArray SceneIndexArray::Copy() const {
    SceneIndexArray out(std::span<const uint32_t> {});
    if (m_capacity > 0 && m_pData != nullptr) {
        out.m_pData = new uint32_t[m_capacity];
        std::memcpy(out.m_pData, m_pData, m_capacity * sizeof(uint32_t));
    }
    out.m_size        = m_size;
    out.m_capacity    = m_capacity;
    out.m_written_bytes = m_written_bytes;
    out.m_render_size = m_render_size;
    out.m_explicit_draw_count = m_explicit_draw_count;
    out.m_width       = m_width;
    return out;
}
