// Clean-room implementation from the WallpaperMachine spec e1b-scene-model.md; written without access to the original source.
#pragma once
#include <vector>
#include <cstdint>
#include <cstddef>
#include <span>
#include <limits>
#include <algorithm>
#include <cstring>

#include "Core/NoCopyMove.hpp"
#include "Core/Literals.hpp"

namespace wallpaper
{
enum class SceneIndexWidth : uint8_t { UInt16, UInt32 };

inline bool CheckedAddU64(uint64_t left, uint64_t right, uint64_t& out) noexcept {
    if (left > std::numeric_limits<uint64_t>::max() - right) return false;
    out = left + right;
    return true;
}

inline bool CheckedMulU64(uint64_t left, uint64_t right, uint64_t& out) noexcept {
    if (right != 0 && left > std::numeric_limits<uint64_t>::max() / right) return false;
    out = left * right;
    return true;
}

/// Last vertex index a packed 16-bit particle mesh can name (four vertices per quad).
inline constexpr uint64_t kMaxUInt16VertexIndex = 65535;
/// 16 384 quads use vertices 0..65535. One more quad needs a 32-bit index.
inline constexpr uint64_t kMaxPackedUInt16Quads = (kMaxUInt16VertexIndex + 1) / 4;
/// Vertex+index payload for one particle mesh. Larger than the old 16-bit
/// single-mesh cap; exceeding it is unsupported.
inline constexpr uint64_t kMaxParticleGeometryBytes = 1ull << 30;

struct ParticleIndexLayout {
    SceneIndexWidth width { SceneIndexWidth::UInt16 };
    uint64_t        quads { 0 };
    uint64_t        vertex_count { 0 };
    uint64_t        index_count { 0 };
    uint64_t        index_bytes { 0 };
    bool            ok { false };
};

inline ParticleIndexLayout PlanParticleIndexLayout(uint64_t quads) noexcept {
    ParticleIndexLayout layout;
    layout.quads = quads;
    if (! CheckedMulU64(quads, 4, layout.vertex_count) ||
        ! CheckedMulU64(quads, 6, layout.index_count)) {
        return layout;
    }
    layout.width = layout.vertex_count > (kMaxUInt16VertexIndex + 1) ? SceneIndexWidth::UInt32
                                                                     : SceneIndexWidth::UInt16;
    const uint64_t element = layout.width == SceneIndexWidth::UInt32 ? 4ull : 2ull;
    if (! CheckedMulU64(layout.index_count, element, layout.index_bytes)) return layout;
    layout.ok = true;
    return layout;
}

inline bool ParticleGeometryFits(uint64_t quads, uint64_t floats_per_vertex,
                                 uint64_t* total_bytes = nullptr) noexcept {
    const auto layout = PlanParticleIndexLayout(quads);
    if (! layout.ok) return false;
    uint64_t floats       = 0;
    uint64_t vertex_bytes = 0;
    uint64_t total        = 0;
    if (! CheckedMulU64(layout.vertex_count, floats_per_vertex, floats) ||
        ! CheckedMulU64(floats, sizeof(float), vertex_bytes) ||
        ! CheckedAddU64(vertex_bytes, layout.index_bytes, total)) {
        return false;
    }
    if (total > kMaxParticleGeometryBytes) return false;
    if (layout.vertex_count > std::numeric_limits<std::size_t>::max()) return false;
    if (layout.index_bytes > std::numeric_limits<std::size_t>::max()) return false;
    if (total_bytes != nullptr) *total_bytes = total;
    return true;
}

class SceneIndexArray : NoCopy {
public:
    SceneIndexArray(usize indexCount);
    SceneIndexArray(usize quadCount, SceneIndexWidth width);
    SceneIndexArray(std::span<const uint32_t> data);

    SceneIndexArray(SceneIndexArray&&) noexcept;
    ~SceneIndexArray();

    /// Writes 32-bit values at 32-bit element `index`; a write that does not fit
    /// the capacity is dropped.
    void Assign(usize index, std::span<const uint32_t> data) {
        WriteBytes(index, sizeof(uint32_t), data.data(), data.size());
    }
    /// Writes 16-bit values at 16-bit element `index`.
    void AssignHalf(usize index, std::span<const uint16_t> data) {
        WriteBytes(index, sizeof(uint16_t), data.data(), data.size());
    }

    const uint32_t* Data() const { return m_pData; }
    usize           DataCount() const { return m_size; }
    usize           DataSizeOf() const { return m_size * sizeof(uint32_t); }

    usize RenderDataCount() const noexcept { return std::min(m_render_size, m_size); }
    void SetRenderDataCount(usize val) noexcept { m_render_size = val; }

    SceneIndexWidth Width() const noexcept { return m_width; }
    usize           ElementSize() const noexcept {
        return m_width == SceneIndexWidth::UInt32 ? sizeof(uint32_t) : sizeof(uint16_t);
    }
    usize QuadCapacity() const noexcept {
        return m_width == SceneIndexWidth::UInt32 ? m_capacity / 6 : m_capacity / 3;
    }
    usize DrawIndexCount() const noexcept {
        const uint64_t units = RenderDataCount();
        if (m_width == SceneIndexWidth::UInt32) {
            return units > std::numeric_limits<usize>::max() ? std::numeric_limits<usize>::max()
                                                             : static_cast<usize>(units);
        }
        uint64_t indices = 0;
        if (! CheckedMulU64(units, 2, indices)) return 0;
        indices = (indices / 3) * 3;
        return indices > std::numeric_limits<usize>::max() ? std::numeric_limits<usize>::max()
                                                           : static_cast<usize>(indices);
    }
    usize DrawIndexBytes() const noexcept {
        uint64_t bytes = 0;
        if (! CheckedMulU64(DrawIndexCount(), ElementSize(), bytes) ||
            bytes > std::numeric_limits<usize>::max()) {
            return 0;
        }
        return static_cast<usize>(bytes);
    }
    void SetDrawIndexCount(usize index_count) noexcept {
        if (m_width == SceneIndexWidth::UInt32) {
            m_render_size = index_count;
            return;
        }
        m_render_size = index_count / 2;
    }

    usize CapacityCount() const { return m_capacity; }
    usize CapacitySizeof() const { return m_capacity * sizeof(uint32_t); }

    uint32_t ID() const { return m_id; }
    void     SetID(uint32_t id) { m_id = id; }

private:
    // Copies `count` elements of `element` bytes to element `index`, when the whole
    // run fits the capacity without any of the arithmetic wrapping.
    void WriteBytes(usize index, usize element, const void* source, usize count) noexcept {
        if (count == 0) return;
        uint64_t last = 0, bytes = 0;
        if (! CheckedAddU64(index, count, last) || ! CheckedMulU64(last, element, bytes)) return;
        if (bytes > static_cast<uint64_t>(m_capacity) * sizeof(uint32_t)) return;
        std::memcpy(reinterpret_cast<char*>(m_pData) + index * element, source, count * element);
        m_size = std::max<usize>(m_size, static_cast<usize>((bytes + 3) / 4));
    }

    uint32_t* m_pData { nullptr };
    usize     m_size { 0 };
    usize     m_capacity { 0 };

    usize m_render_size { std::numeric_limits<usize>::max() };

    SceneIndexWidth m_width { SceneIndexWidth::UInt16 };
    uint32_t        m_id { 0 };
};
} // namespace wallpaper
