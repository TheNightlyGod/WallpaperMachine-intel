// Clean-room implementation from the WallpaperMachine spec e1b-scene-model.md; written without access to the original source.
#include "SceneVertexArray.h"

#include <algorithm>
#include <limits>
#include <utility>

using namespace wallpaper;

uint8_t SceneVertexArray::TypeCount(VertexType t) {
    // The enumerators run through the four float widths and then the four unsigned
    // widths, so the width is the position within its group of four, plus one.
    const int ordinal = static_cast<int>(t);
    if (ordinal < static_cast<int>(VertexType::FLOAT1) || ordinal > static_cast<int>(VertexType::UINT4))
        return 1;
    return static_cast<uint8_t>(ordinal % 4 + 1);
}

uint8_t SceneVertexArray::RealAttributeSize(const SceneVertexArray::SceneVertexAttribute& attr) {
    return attr.padding ? 4 : TypeCount(attr.type);
}

SceneVertexArray::SceneVertexArray(const std::vector<SceneVertexAttribute>& attrs,
                                   const usize                              count)
    : m_attrs(attrs) {
    for (const auto& attr : m_attrs) m_stride += RealAttributeSize(attr);
    if (m_stride == 0 || count == 0) return;
    if (count > std::numeric_limits<usize>::max() / m_stride) return; // too large to address
    const usize words = count * m_stride;
    if (words > std::numeric_limits<usize>::max() / sizeof(float)) return;
    m_capacity = words;
    m_data     = std::make_unique<float[]>(words); // value-initialised: zero
}

SceneVertexArray::~SceneVertexArray() = default;

SceneVertexArray::SceneVertexArray(SceneVertexArray&& o) noexcept
    : m_attrs(std::move(o.m_attrs)),
      m_stride(std::exchange(o.m_stride, 0)),
      m_capacity(std::exchange(o.m_capacity, 0)),
      m_size(std::exchange(o.m_size, 0)),
      m_data(std::move(o.m_data)),
      m_options(std::move(o.m_options)),
      m_id(std::exchange(o.m_id, 0)) {
    o.m_attrs.clear();
    o.m_options.clear();
}

SceneVertexArray& SceneVertexArray::operator=(SceneVertexArray&& o) noexcept {
    if (this == &o) return *this;
    m_attrs    = std::move(o.m_attrs);
    m_stride   = std::exchange(o.m_stride, 0);
    m_capacity = std::exchange(o.m_capacity, 0);
    m_size     = std::exchange(o.m_size, 0);
    m_data     = std::move(o.m_data); // frees what this array held
    m_options  = std::move(o.m_options);
    m_id       = std::exchange(o.m_id, 0);
    o.m_attrs.clear();
    o.m_options.clear();
    return *this;
}

bool SceneVertexArray::AddVertex(const float* data) {
    if (m_stride == 0 || m_size > m_capacity || m_capacity - m_size < m_stride) return false;
    float* vertex = m_data.get() + m_size;
    std::fill(vertex, vertex + m_stride, 0.0f);
    usize next = 0;
    for (const auto& attr : m_attrs) {
        const usize components = TypeCount(attr.type);
        std::copy(data, data + components, vertex + next);
        data += components;
        next += RealAttributeSize(attr);
    }
    m_size += m_stride;
    return true;
}

bool SceneVertexArray::SetVertex(std::string_view name, std::span<const float> data) noexcept {
    // The last attribute of a name wins, as in the offset map.
    const SceneVertexAttribute* found = nullptr;
    usize                       word  = 0;
    usize                       at    = 0;
    for (const auto& attr : m_attrs) {
        if (attr.name == name) {
            found = &attr;
            word  = at;
        }
        at += RealAttributeSize(attr);
    }
    if (found == nullptr) return false;

    const usize components = TypeCount(found->type);
    const usize count      = data.size() / components;
    if (count > m_capacity / m_stride) return false;
    for (usize vertex = 0; vertex < count; ++vertex) {
        std::copy_n(data.data() + vertex * components, components,
                    m_data.get() + vertex * m_stride + word);
    }
    m_size = std::max(m_size, count * m_stride);
    return true;
}

bool SceneVertexArray::SetVertexs(usize index, std::span<const float> data) noexcept {
    if (data.empty()) return true;
    usize start = 0, end = 0;
    if (__builtin_mul_overflow(index, m_stride, &start) ||
        __builtin_add_overflow(start, data.size(), &end) || end > m_capacity) {
        return false;
    }
    std::copy(data.begin(), data.end(), m_data.get() + start);
    m_size = std::max(m_size, end);
    return true;
}

Map<std::string, SceneVertexArray::SceneVertexAttributeOffset>
SceneVertexArray::GetAttrOffsetMap() const {
    Map<std::string, SceneVertexAttributeOffset> map;
    usize                                        words = 0;
    for (const auto& attr : m_attrs) {
        map.insert_or_assign(attr.name, SceneVertexAttributeOffset { attr, words * sizeof(float) });
        words += RealAttributeSize(attr);
    }
    return map;
}

bool SceneVertexArray::GetOption(std::string_view name) const {
    const auto found = m_options.find(name);
    return found != m_options.end() && found->second;
}
void SceneVertexArray::SetOption(std::string_view name, bool value) {
    m_options.insert_or_assign(std::string(name), value);
}
