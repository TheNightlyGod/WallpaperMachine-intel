// Clean-room implementation from the WallpaperMachine spec e1b-scene-model.md; written without access to the original source.
#pragma once
#include <vector>
#include <string>
#include <cstddef>
#include <string_view>
#include <span>
#include <memory>
#include "Core/MapSet.hpp"

#include "Core/Literals.hpp"
#include "Core/NoCopyMove.hpp"
#include "Type.hpp"

namespace wallpaper
{

class SceneVertexArray : NoCopy {
public:
    struct SceneVertexAttribute {
        std::string name;
        VertexType  type;
        bool        padding { true };
    };
    struct SceneVertexAttributeOffset {
        SceneVertexAttribute attr;
        usize                offset;
    };

    // `count` vertices of room, laid out as `attrs` says.
    SceneVertexArray(const std::vector<SceneVertexAttribute>& attrs, const std::size_t count);
    ~SceneVertexArray();
    SceneVertexArray(SceneVertexArray&&) noexcept;
    SceneVertexArray& operator=(SceneVertexArray&&) noexcept;

    // Filling: append a whole vertex, or write one attribute / one vertex in place.
    bool AddVertex(const float*);   // one vertex of `OneSize()` words, at the end
    bool SetVertex(std::string_view name, std::span<const float> data) noexcept;
    bool SetVertexs(std::size_t index, std::span<const float> data) noexcept;

    // Per-array flags by name.
    bool GetOption(std::string_view) const;
    void SetOption(std::string_view, bool);

    // Reading back. Sizes are counted in 4-byte words; the `...Of` forms are in bytes.
    const float* Data() const { return m_data.get(); }
    usize DataSize() const { return m_size; }                                 // words filled
    usize DataSizeOf() const { return m_size * sizeof(float); }               // bytes filled
    usize VertexCount() const { return m_stride == 0 ? 0 : m_size / m_stride; }  // no divide by 0
    usize CapacitySize() const { return m_capacity; }                         // words allocated
    usize CapacitySizeOf() const { return m_capacity * sizeof(float); }       // bytes allocated
    usize        OneSize() const { return m_stride; }
    usize        OneSizeOf() const { return m_stride * sizeof(float); }

    const auto&                                  Attributes() const { return m_attrs; }
    Map<std::string, SceneVertexAttributeOffset> GetAttrOffsetMap() const;

    uint32_t ID() const { return m_id; }
    void     SetID(uint32_t id) { m_id = id; }

    static uint8_t TypeCount(VertexType);
    static uint8_t RealAttributeSize(const SceneVertexAttribute&);

private:
    std::vector<SceneVertexAttribute> m_attrs;
    usize                             m_stride { 0 };   // words per vertex
    usize                             m_capacity { 0 }; // words
    usize                             m_size { 0 };     // words filled
    std::unique_ptr<float[]>          m_data;
    Map<std::string, bool>            m_options;
    uint32_t                          m_id { 0 };
};
} // namespace wallpaper
